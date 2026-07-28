@preconcurrency import AVFoundation
import CoreAudio
import CoreGraphics
import FluidAudio
import Observation
import os
import SpeakerKit
import WhisperKit

/// Subsystem all of Tome's logging shares. Matches the per-type `Logger`s (e.g.
/// `StreamingTranscriber`) so `log show --predicate 'subsystem == "com.dloomis.tome"'`
/// returns everything in one stream.
let tomeLogSubsystem = "com.dloomis.tome"

private let diagLogger = Logger(subsystem: tomeLogSubsystem, category: "diag")

/// Diagnostic logging, routed through the unified logging system. Replaces the
/// former `/tmp/tome.log` file writer — which was world-readable, opened and
/// closed the file on *every* call, and raced on concurrent writes from the audio
/// threads. Emitted at `.notice` so it's persisted to the log store and reliably
/// retrievable after the fact (the File ▸ Logs menu shells out to `log show`);
/// `.debug`/`.info` are memory-only and would be gone by the time the user looks.
/// Messages are marked public because they carry only diagnostic metadata —
/// counts, audio formats, filenames, error text — never transcript content.
func diagLog(_ msg: String) {
    diagLogger.notice("\(msg, privacy: .public)")
}

/// `diagLog` at `.error` — for events that lose or endanger user data (transcript
/// disappearance, write failures, failed finalize jobs). Same persistence as
/// `.notice`, but errors survive longer in the log store and stand out when
/// triaging a `log show` capture.
func diagLogError(_ msg: String) {
    diagLogger.error("\(msg, privacy: .public)")
}

/// Dual-stream mic + system audio transcription.
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    var assetStatus: String = "Ready"
    var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()

    /// Device-backed system leg ("lean-in" mode): when the user points the call
    /// audio source at a mixer's virtual input device, the "Them" leg is captured
    /// through a SECOND `MicCapture` instead of ScreenCaptureKit. `MicCapture` is
    /// reused deliberately — device binding with surfaced errors, append-reopen
    /// crash-safe WAV retention, the HAL fast-path listener, the
    /// delivery/first-sample timestamps and the unfed-virtual-device detector are
    /// all exactly what a device leg needs, and all of it is already hardened by
    /// the AirPods/HAL incidents. Two AVAudioEngine input captures on different
    /// devices are fine: each engine binds its own HAL unit.
    private let systemDeviceCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Combined audio level from mic and system for the UI meter.
    var audioLevel: Float {
        max(micCapture.audioLevel, max(systemCapture.audioLevel, systemDeviceCapture.audioLevel))
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    /// Monotonic session token, bumped at the top of every `start()` and `stop()`.
    /// Async rebuilds (`restartSystemAudioLeg`) capture it on entry and re-check
    /// after each suspension: `isRunning` alone can't tell "still this session"
    /// from "stopped and immediately restarted", and during `stop()`'s long drain
    /// `isRunning` is still true — a rebuild racing that window would otherwise
    /// spin up a fresh SCStream + sysTask that nothing tears down.
    private var sessionGeneration = 0

    /// Polls `SystemAudioCapture.lastSampleTime` and surfaces a warning if SCStream
    /// silently stops delivering samples (display sleep without our activity assertion,
    /// permission revoked mid-session, captured app quit, etc.).
    private var sysWatchdogTask: Task<Void, Never>?

    /// Activity token preventing App Nap, idle system sleep, and idle display sleep
    /// while a recording is live. Without this, ScreenCaptureKit pauses when the
    /// display blanks and the engine appears stuck in "transcribing" while capturing
    /// nothing.
    private var liveActivity: (any NSObjectProtocol)?

    /// Shared, serialized ASR access. Injected so the same coordinator is shared with
    /// `PostProcessingQueue` — live streaming and batch re-transcription must route
    /// through one actor for safe interleaving.
    let asrCoordinator: ASRCoordinator
    private var vadManager: VadManager?

    /// The WAV buffer path for the currently-capturing session. The engine owns this URL
    /// between start and stop; post-processing methods use it explicitly rather than
    /// reaching into `SystemAudioCapture`.
    private var currentBufferURL: URL?

    /// The mic-track retention WAV path for the currently-capturing session, mirroring
    /// `currentBufferURL`. Always set when a `recordingContext` is supplied (capture is
    /// unconditional); the post-processing job decides whether to keep it.
    private var currentMicBufferURL: URL?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// The user's mic selection as a persisted device UID ("" = System Default).
    /// UID, not AudioDeviceID: numeric IDs are transient across driver reloads /
    /// reboots (third-party HAL drivers especially), so the intent is stored
    /// stably and re-resolved to a live ID at EVERY bind attempt — start,
    /// restart, and watchdog rebuilds all aim at this.
    private var userSelectedDeviceUID: String = ""

    /// The session's audio-router exclusion list (AppSettings.excludedAudioAppIDs
    /// at start time), retained like `activeRecordingContext` so system-leg
    /// rebuilds re-apply the same SCContentFilter. Only consulted in automatic
    /// (SCK) mode — device mode never builds an `SCContentFilter`.
    private var activeExcludedAudioAppIDs: [String] = []

    /// The session's call-audio source selection (AppSettings.systemAudioSourceUID
    /// at start time). "" = automatic/SCK. Retained — not collapsed to a resolved
    /// device ID — so every rebuild RE-RESOLVES it: a device that was absent at
    /// start is adopted the moment it reappears, exactly like the mic UID.
    private var activeSystemSourceUID: String = ""

    /// Which capture object the system leg is reading from right now. Held in a
    /// lock rather than as a plain property because the capture watchdog polls it
    /// from a background task to pick which leg's timestamps to read.
    private let _systemSourceMode = OSAllocatedUnfairLock<SystemSourceMode>(uncheckedState: .sck)
    private var systemSourceMode: SystemSourceMode {
        get { _systemSourceMode.withLock { $0 } }
        set { _systemSourceMode.withLock { $0 = newValue } }
    }

    /// Where the system ("Them") leg is captured from for the current session.
    enum SystemSourceMode: Sendable, Equatable {
        /// ScreenCaptureKit over the whole display, minus exclusions. The default.
        case sck
        /// A user-selected CoreAudio input device (a mixer's published mix).
        case device(AudioDeviceID)

        var isDevice: Bool { if case .device = self { return true } else { return false } }
    }

    /// Why a session configured for device mode is running on SCK instead. Each
    /// reason is user-visible (Part C of the mixer-device spec): a session
    /// recording from the "wrong" source must never be silent.
    enum SystemSourceFallbackReason: Sendable, Equatable {
        /// The configured UID resolves to no present input device.
        case deviceUnavailable
        /// The configured device IS the mic's device — capturing it on both legs
        /// would transcribe every utterance twice.
        case sameAsMic
        /// The device resolved but the capture failed to bind.
        case bindFailed
    }

    /// Outcome of resolving the session's call-audio source. Pure — see
    /// `resolveSystemSource`.
    enum SystemSourceResolution: Sendable, Equatable {
        case sck
        case device(AudioDeviceID)
        case sckFallback(SystemSourceFallbackReason)
    }

    /// Non-nil while the system leg is running on SCK despite a configured
    /// device source. Rendered as a persistent ControlBar banner alongside
    /// `micFallbackMessage`; the selection itself is never changed, so every
    /// rebuild keeps aiming at the chosen device.
    private(set) var systemSourceFallbackMessage: String?

    /// Non-nil while capture runs on a device OTHER than the user's selection
    /// (unresolvable UID at start, or an emergency fallback after a failed
    /// bind). Rendered as a persistent ControlBar banner; the selection itself
    /// is never changed — rebuild attempts keep aiming at the chosen device.
    private(set) var micFallbackMessage: String?

    /// One-shot check that the mic is delivering real audio (not exact digital
    /// zeros — the signature of an unfed virtual router device or a hard-muted
    /// input). Armed per start(), cancelled in stop().
    private var micSilenceCheckTask: Task<Void, Never>?

    /// Neutral "mic is muted or silent" line — posted instead of a red error
    /// when the mic delivers digital zeros but its feeder app is running
    /// (2026-07-25 false-positive fix: a Wave Link mute renders exact zeros
    /// into a fed mix, and that's user intent, not a fault). Rendered as a
    /// gray ControlBar line, never routed to `lastError`.
    private(set) var micSilenceHintMessage: String?

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Listens for changes to the system-wide DEVICE LIST while a session runs
    /// with a pinned mic and/or a configured call-audio source — the re-adoption
    /// trigger the 2026-07-25 field test showed was missing. Wave Link
    /// republishes its virtual devices when its own output device changes (a
    /// Bluetooth HFP flip does exactly that), so a mid-flip rebuild finds the
    /// configured UID unresolvable and falls back to SCK — correct — but a
    /// healthy SCK leg never rebuilds, so the session stayed on SCK even after
    /// the device returned seconds later. The mic leg had the same hole with a
    /// more everyday trigger: a laptop docked mid-session left capture on the
    /// built-in mic for the rest of the recording, because the only mic-side
    /// listener watches the OS DEFAULT device and is inert while a specific
    /// device is pinned. A device-list change is the precise "it may be back"
    /// signal for both legs; each handler re-resolves and rebuilds only when its
    /// own selection is actually adoptable again.
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    /// Debounced re-adoption check scheduled by the device-list listener.
    /// Device-list changes arrive in storms during the exact transitions that
    /// make mixers republish devices; each new change supersedes the pending one.
    private var deviceReadoptionTask: Task<Void, Never>?

    /// Mic-leg counterpart of `deviceReadoptionTask`, same debounce and the same
    /// supersede-the-pending-one rule. Separate task because the two legs
    /// re-adopt independently — docking restores the pinned mic whether or not a
    /// call-audio device came back with it.
    private var micReadoptionTask: Task<Void, Never>?

    /// Debounced mic rebuild scheduled by `AVAudioEngineConfigurationChange`.
    /// Bluetooth transitions (AirPods connect, HFP↔A2DP renegotiation) fire the
    /// notification in flurries and kill the tap each time; the debounce lets the
    /// audio graph settle so the rebuild lands on stable ground. If a rebuild
    /// itself gets killed by a late transition, the next notification simply
    /// schedules another — a self-healing loop with natural backoff.
    private var micRebuildTask: Task<Void, Never>?

    init(transcriptStore: TranscriptStore, asrCoordinator: ASRCoordinator) {
        self.transcriptStore = transcriptStore
        self.asrCoordinator = asrCoordinator
    }

    func start(
        locale: Locale,
        inputDeviceUID: String = "",
        recordingContext: SessionRecordingContext? = nil,
        captureSystemAudio: Bool = true,
        excludedAudioAppIDs: [String] = [],
        systemAudioSourceUID: String = ""
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        sessionGeneration += 1
        lastError = nil

        guard await ensureMicrophonePermission() else { return }

        isRunning = true
        // Fresh session — reset the startup-delivery gate's one-shot latch and
        // clear any stale handle from a prior start().
        startupGateFired = false
        startupGateTask?.cancel()
        startupGateTask = nil
        // System-audio startup gate (mic gate's system-side analogue).
        sysStartupGateFired = false
        sysStartupGateTask?.cancel()
        sysStartupGateTask = nil
        // Retained so the system-audio startup gate can rebuild the leg without
        // re-plumbing it from ContentView.
        activeRecordingContext = recordingContext
        beginLiveActivity()

        // 1. Verify ASR readiness. Model download/load lives in
        //    ModelProvisioner; the UI gates recording on readiness, so this
        //    is a formality — but API starts and races land here too.
        do {
            guard await asrCoordinator.isReady else {
                throw ASRCoordinatorError.notInitialized
            }
            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] models ready")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            endLiveActivity()
            return
        }

        guard let vadManager else { return }

        // stopSession can run while the model load above was suspended: stop()
        // flips isRunning false and tears down (nothing yet). Without this
        // re-check, start would proceed to bring up capture + watchdog for a
        // session the UI already considers dead — mic left recording with the
        // app showing idle.
        guard isRunning else {
            diagLog("[ENGINE-2-ABORT] stopped during model load — not starting capture")
            assetStatus = "Ready"
            return
        }

        // 2. Start mic capture
        // Route/graph changes stop the engine silently (observed: AirPods
        // connecting killed a running Brio tap with zero errors) — rebuild the
        // mic when that happens instead of waiting for the 15s stall watchdog.
        micCapture.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.scheduleMicRebuild(reason: "engine configuration change") }
        }
        userSelectedDeviceUID = inputDeviceUID
        activeExcludedAudioAppIDs = excludedAudioAppIDs
        activeSystemSourceUID = captureSystemAudio ? systemAudioSourceUID : ""
        systemSourceMode = .sck
        micFallbackMessage = nil
        systemSourceFallbackMessage = nil
        // Resolve the mic device. A HAL that never answers is NOT the same as a
        // device that isn't there: answering "unavailable" with the system
        // default is how a single wedged bind used to poison the next start —
        // the UID lookup was refused, the engine concluded the selected mic had
        // vanished, posted "recording from the system default microphone", and
        // aimed at the default, which on this machine IS the wedged device
        // (2026-07-27). A degraded lookup fails the start instead, with the
        // driver-not-responding wording that tells the user to wait.
        let selectionLookup = inputDeviceUID.isEmpty
            ? await MicCapture.defaultInputDeviceIDResult()
            : await MicCapture.deviceIDResult(forUID: inputDeviceUID)
        let targetMicID: AudioDeviceID?
        switch Self.resolveMicTarget(selectedUID: inputDeviceUID, selectionLookup: selectionLookup) {
        case .bind(let resolved):
            targetMicID = resolved
        case .useSystemDefault:
            // The persisted UID resolves to no present device. Fall back to the
            // system default FOR THIS SESSION and say so — the old behavior
            // recorded a whole meeting off the built-in mic with no indication.
            // The selection is preserved; watchdog rebuilds keep aiming at it.
            switch await MicCapture.defaultInputDeviceIDResult() {
            case .answered(let fallbackID):
                targetMicID = fallbackID
                await reportMicFallback(boundDeviceID: fallbackID)
            case .unavailable:
                failStartWithUnresponsiveHAL(deviceName: nil)
                return
            }
        case .abort:
            failStartWithUnresponsiveHAL(deviceName: nil)
            return
        }
        currentMicDeviceID = targetMicID ?? 0
        currentMicBufferURL = recordingContext.flatMap { ctx in
            try? SystemAudioCapture.sessionsDirectory().appendingPathComponent("\(ctx.sessionId).mic.wav")
        }
        diagLog("[ENGINE-3] starting mic capture, targetMicID=\(String(describing: targetMicID)), micBuffer=\(currentMicBufferURL?.lastPathComponent ?? "nil")")

        // Mic-only sessions carry their crash-recovery sidecar on the mic WAV.
        // SystemAudioCapture emits one for call captures, but voice memos never
        // reach it — which left crashed memos invisible to the orphan scanner.
        // Sample rate is nominal; recovery reads the WAV header itself.
        if !captureSystemAudio, let ctx = recordingContext, let micURL = currentMicBufferURL {
            SessionSidecar.emit(forWAV: micURL, context: ctx, sampleRate: 48_000)
        }

        let micBind = await micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)

        // The bind now suspends (HAL queue + 5s deadline — 2026-07-25 hang
        // fix); a stop() could have run while it was in flight.
        guard isRunning else {
            diagLog("[ENGINE-3-ABORT] stopped during mic bind — unwinding")
            await micCapture.stop()
            assetStatus = "Ready"
            return
        }

        // A session with no working mic must not pretend to record — fail the
        // start and let ContentView's rollback unwind the bookkeeping.
        let micStream: AsyncStream<AVAudioPCMBuffer>
        switch micBind {
        case .success(let stream):
            micStream = stream
        case .failure(let bindError):
            var name: String?
            if let targetMicID { name = await MicCapture.deviceName(for: targetMicID) }
            let msg = Self.micBindFailureText(error: bindError, deviceName: name)
            diagLog("[ENGINE-3-FAIL] mic capture failed at start: \(msg)")
            lastError = msg
            // The unresolvable-UID path above may have already posted the
            // "recording from <default>" fallback banner + notification — but
            // this start is failing, so nothing records. Retract it rather than
            // leave a notification claiming a live recording that isn't.
            clearMicFallback()
            // A timed-out/wedged bind must NOT be touched — the abandoned-op
            // handler owns its teardown, and a fallback retry against another
            // device would only queue behind the same wedge (the system
            // default usually IS the wedged device). Only a clean setup
            // failure gets the normal stop.
            if case .setupFailed = bindError {
                await micCapture.stop()
            }
            // No audio was ever delivered — remove the just-provisioned mic
            // artifacts (header-only WAV + sidecar) so they don't accumulate as
            // sub-threshold junk the orphan scanner can never surface.
            if let micURL = currentMicBufferURL {
                try? FileManager.default.removeItem(at: micURL)
                SessionSidecar.deleteIfExists(forWAV: micURL)
            }
            assetStatus = "Ready"
            isRunning = false
            endLiveActivity()
            return
        }

        // Startup-delivery gate: the mic engine is up, but on AirPods the first
        // engine open can race the A2DP→HFP profile flip — start() succeeds
        // against the stale 48 kHz format, the profile then flips, and the tap
        // delivers nothing with no error and no config-change (the HAL fast path
        // above is the primary backstop; this is belt-and-suspenders for when the
        // flip races even that). Force ONE mic restart at 3s if no sample ever
        // arrives, collapsing the 15s watchdog wait.
        armStartupDeliveryGate()
        armMicDigitalSilenceCheck()

        // 3. Start system audio capture. Skipped for mic-only sessions (voice memos /
        //    in-person meetings) — there the mic is the sole source and diarization runs
        //    on the mic track, so capturing system audio would only add a stray "Them"
        //    stream and a needless ScreenCaptureKit permission prompt.
        let sysStream: AsyncStream<AVAudioPCMBuffer>?
        // Clear before the bring-up, not after: a bring-up that fails must leave
        // NO buffer URL, or stopSession would snapshot the previous session's
        // (already cleaned-up) WAV path into this session's job. Rebuilds
        // deliberately keep the existing URL on failure — the WAV captured so far
        // is still the one to finalize.
        currentBufferURL = nil
        if captureSystemAudio {
            sysStream = await bringUpSystemLeg(recordingContext: recordingContext)
        } else {
            diagLog("[ENGINE-4] system audio capture skipped (mic-only session)")
            sysStream = nil
            currentBufferURL = nil
        }

        // Same stop-during-await race as after model load: the system-audio
        // bring-up suspended above. If stop ran meanwhile, unwind the capture we
        // just started instead of leaving a headless recording.
        guard isRunning else {
            diagLog("[ENGINE-4-ABORT] stopped during capture bring-up — unwinding")
            await micCapture.stop()
            await systemDeviceCapture.stop()
            await systemCapture.stop()
            assetStatus = "Ready"
            return
        }

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrCoordinator: asrCoordinator,
            vad: SileroVADStream(manager: vadManager),
            speaker: .you,
            audioSource: .microphone,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            // Awaited (not fire-and-forget): stop() drains the transcriber task,
            // and that drain must guarantee the utterance is IN the store when it
            // returns — stopSession snapshots the transcript right after.
            onFinal: { text, startTime in
                await MainActor.run {
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you, timestamp: startTime))
                }
            }
        )
        let reportMicError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.lastError = msg }
        }
        micTask = Task.detached {
            let hadFatalError = await micTranscriber.run(stream: micStream)
            if hadFatalError {
                reportMicError("Mic transcription failed — restart session")
            }
        }

        // 5. Start system audio transcription
        if let sysStream {
            spinUpSystemTranscription(stream: sysStream, vadManager: vadManager)
        }

        // 5b. System-audio startup-delivery gate: SCStream's per-stream cold start
        //     can race the same way the mic's A2DP→HFP flip does — startCapture()
        //     succeeds but the tap delivers nothing, with no didStopWithError. Force
        //     ONE rebuild of the system leg if no sample lands within the window,
        //     collapsing the wait before the 15s stall watchdog would alarm. Only
        //     armed when we actually brought the leg up.
        if sysStream != nil {
            armSystemStartupDeliveryGate()
        }

        // Watch BOTH capture legs, not just system audio — a mic that stops
        // delivering (device pulled, HAL wedge) is silent loss of the user's own
        // side, and flowing system audio masks it from the level-based silence
        // detection entirely.
        startCaptureWatchdog(systemLegActive: sysStream != nil)

        let modelName = await asrCoordinator.activeModel?.displayName ?? "ASR"
        assetStatus = "Transcribing (\(modelName))"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()

        // Re-adoption trigger for whichever selections can go missing: a mixer
        // that republishes its devices mid-session (BT-flip storm), or a pinned
        // mic that comes back when the laptop is docked — both must be adopted
        // when the device returns. See `deviceListListenerBlock`.
        if !activeSystemSourceUID.isEmpty || !userSelectedDeviceUID.isEmpty {
            installDeviceListListener()
        }
    }

    /// One-shot handle for the startup-delivery gate armed in `start()`. See
    /// `armStartupDeliveryGate`. Cancelled in `stop()`.
    private var startupGateTask: Task<Void, Never>?

    /// Set once the startup-delivery gate has forced its single restart, so it
    /// never fires twice within one `start()` even across a `restartMic` that
    /// re-arms nothing. Reset at the top of each `start()`.
    private var startupGateFired = false

    /// System-audio analogue of `startupGateTask`/`startupGateFired`. One-shot per
    /// `start()`: rebuild the system leg once if it never delivers a sample.
    private var sysStartupGateTask: Task<Void, Never>?
    private var sysStartupGateFired = false

    /// "Has the system leg delivered a buffer since its CURRENT bind?" — the
    /// signal both delivery gates need, expressed per source because the two
    /// captures reset different fields:
    ///
    /// - SCK resets `firstSampleTime` on `stop()`, and seeds `lastSampleTime` at
    ///   bring-up, so `firstSampleTime` is the honest one.
    /// - `MicCapture` deliberately PRESERVES `firstSampleTime` across a rebuild
    ///   (it anchors the retained WAV to the session start, not to the restart,
    ///   which is what makes append-reopen correct) and instead nils
    ///   `lastSampleTime` on `stop()`, writing it only from the tap. So there
    ///   `lastSampleTime` is the honest one — using `firstSampleTime` would make
    ///   the post-rebuild grace check permanently inert in device mode.
    ///
    /// Distinct from `systemFirstSampleTime`, which is the session-anchor the
    /// post-session mixer consumes and must keep its cross-rebuild semantics.
    private var systemLegSampleSinceBind: Date? {
        systemSourceMode.isDevice ? systemDeviceCapture.lastSampleTime : systemCapture.firstSampleTime
    }

    /// One-shot grace check armed after each successful system-leg rebuild. A
    /// rebuild re-seeds the stall watchdog's clock (`bufferStream` seeds
    /// `_lastSampleTime` at start), so a rebuilt-but-still-silent leg wouldn't
    /// trip the 15s watchdog until ~15s AFTER the rebuild — this alarms directly
    /// at +5s instead. Cancelled in `stop()`.
    private var sysRebuildGraceTask: Task<Void, Never>?

    /// The current session's recording context, retained so the system-audio
    /// startup gate can rebuild the leg (it needs the same sidecar/WAV identity)
    /// without ContentView re-plumbing it. Set at `start()`, cleared at `stop()`.
    private var activeRecordingContext: SessionRecordingContext?

    /// Spin up the "Them" transcriber over a system-audio stream. Extracted from
    /// `start()` so the system-audio startup gate can re-establish the leg on a
    /// freshly-rebuilt stream without duplicating the wiring.
    private func spinUpSystemTranscription(stream: sending AsyncStream<AVAudioPCMBuffer>, vadManager: VadManager) {
        let store = transcriptStore
        let sysTranscriber = StreamingTranscriber(
            asrCoordinator: asrCoordinator,
            vad: SileroVADStream(manager: vadManager),
            speaker: .them,
            audioSource: .system,
            onPartial: { text in
                Task { @MainActor in store.volatileThemText = text }
            },
            onFinal: { text, startTime in
                await MainActor.run {
                    store.volatileThemText = ""
                    store.append(Utterance(text: text, speaker: .them, timestamp: startTime))
                }
            }
        )
        let reportSysError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.lastError = msg }
        }
        sysTask?.cancel()
        sysTask = Task.detached {
            let hadFatalError = await sysTranscriber.run(stream: stream)
            if hadFatalError {
                reportSysError("System audio transcription failed — restart session")
            }
        }
    }

    // MARK: - System leg bring-up (SCK vs. device)

    /// Pure resolution of the session's call-audio source, shared by `start()`
    /// and every rebuild. Extracted (injected resolvers, like
    /// `AppSettings.migratedInputSelection`) so the four outcomes are testable
    /// without audio hardware.
    ///
    /// The same-as-mic guard is the load-bearing one: capturing one device on
    /// BOTH legs transcribes every utterance twice — the exact defect device
    /// mode exists to prevent. Settings warns at selection time too, but a
    /// settings race (mic changed after the source was picked) must not be able
    /// to produce a double-capture session, so the engine refuses it outright.
    nonisolated static func resolveSystemSource(
        uid: String,
        resolvedDeviceID: AudioDeviceID?,
        micDeviceID: AudioDeviceID
    ) -> SystemSourceResolution {
        guard !uid.isEmpty else { return .sck }
        guard let resolvedDeviceID else { return .sckFallback(.deviceUnavailable) }
        guard resolvedDeviceID != micDeviceID else { return .sckFallback(.sameAsMic) }
        return .device(resolvedDeviceID)
    }

    /// Pure decision for the device-list re-adoption trigger: rebuild the
    /// system leg only when a session is live, configured for a device source,
    /// currently running the leg on SCK (a fallback), and the source now
    /// resolves to an adoptable device. `.sckFallback` resolutions must NOT
    /// rebuild — the leg would only land back on SCK, and the pointless
    /// teardown/bring-up rotates the session WAV for nothing (same-as-mic
    /// configs would do that on every device-list change).
    nonisolated static func shouldReadoptDeviceSource(
        isRunning: Bool,
        configuredUID: String,
        legIsOnDevice: Bool,
        resolution: SystemSourceResolution
    ) -> Bool {
        guard isRunning, !configuredUID.isEmpty, !legIsOnDevice else { return false }
        if case .device = resolution { return true }
        return false
    }

    /// Mic-leg counterpart of `shouldReadoptDeviceSource`: may the device-list
    /// listener swap capture back onto the user's pinned microphone?
    ///
    /// Only when a session is live, a specific device is pinned (System Default
    /// follows the OS through `installDefaultDeviceListener` and must never be
    /// second-guessed here), and the pinned UID now resolves to a device we are
    /// NOT already recording from — the dock-the-laptop case, where `start()`
    /// fell back to the built-in mic because the dock's mic was absent.
    ///
    /// `.unavailable` returns false, for the 2026-07-27 reason: a lookup the HAL
    /// never answered says nothing about which devices exist, and tearing down a
    /// working mic on the strength of one is how a single wedge cascades. The
    /// wedge-cleared path re-fires the enumeration, and `restartMic` re-checks
    /// everything anyway.
    nonisolated static func shouldReadoptMicDevice(
        isRunning: Bool,
        selectedUID: String,
        currentMicDeviceID: AudioDeviceID,
        selectionLookup: HALQueryResult<AudioDeviceID?>
    ) -> Bool {
        guard isRunning, !selectedUID.isEmpty else { return false }
        guard case .answered(let resolved) = selectionLookup, let resolved else { return false }
        return resolved != currentMicDeviceID
    }

    /// User-facing text for a system leg that carried no audible content — the
    /// watchdog's 60s warning (`atStop: false`) and ContentView's end-of-session
    /// note (`atStop: true`). Mode-aware: in device mode the exclusion list is
    /// inert, so pointing the user at it would be a dead end; what they can
    /// actually fix is the mixer's mix routing.
    nonisolated static func systemAudioSilentDetail(deviceMode: Bool, atStop: Bool) -> String {
        switch (deviceMode, atStop) {
        case (true, false):
            return "No call audio detected yet. If the other side is talking, check your mixer's mix routing — the mix Tome captures may be empty."
        case (true, true):
            return "This recording captured no call audio — the transcript contains only your side. Check that your mixer was running and that the mix Tome captures carries the call's audio."
        case (false, false):
            return "No system audio detected yet. If the other side is talking, check the call audio source in Settings \u{25B8} Audio."
        case (false, true):
            return "This recording captured no system audio — the transcript contains only your side. If the other side was routed through an audio router, review the call audio source in Settings \u{25B8} Audio."
        }
    }

    /// User-facing text for each fallback reason. Pure so the wording is
    /// unit-testable and identical between the banner and the notification.
    ///
    /// `mayPromptForScreenRecording`: pass true when Screen Recording permission
    /// has never been granted (`!CGPreflightScreenCaptureAccess()`) — automatic
    /// capture will raise the system permission dialog, and for a device-mode
    /// user (the mode exists partly to avoid that permission) it would otherwise
    /// appear out of nowhere, possibly mid-call.
    nonisolated static func systemSourceFallbackText(
        reason: SystemSourceFallbackReason,
        deviceName: String?,
        mayPromptForScreenRecording: Bool = false
    ) -> String {
        let name = deviceName.map { "\u{201C}\($0)\u{201D}" } ?? "The selected call audio device"
        let base: String
        switch reason {
        case .deviceUnavailable:
            base = "\(name) is unavailable — capturing system audio automatically instead. Your Settings choice is unchanged."
        case .sameAsMic:
            base = "The call audio source is the same device as your microphone — capturing system audio automatically instead, so you aren't transcribed twice."
        case .bindFailed:
            base = "\(name) couldn't be opened — capturing system audio automatically instead. Your Settings choice is unchanged."
        }
        guard mayPromptForScreenRecording else { return base }
        return base + " macOS may ask for Screen Recording permission to allow this."
    }

    /// User-facing text for a failed mic bind. The timed-out/wedged cases are
    /// the 2026-07-25 hang fix: specific and actionable, because the failure
    /// is almost always a driver still starting up — and deliberately NOT
    /// retried against the system default (Part C of the spec): when the
    /// wedge is driver-wide, the default IS the wedged device.
    nonisolated static func micBindFailureText(error: CaptureBindError, deviceName: String?) -> String {
        switch error {
        case .setupFailed(let message):
            return message
        case .timedOut, .halWedged:
            let name = deviceName.map { "\u{201C}\($0)\u{201D}" } ?? "The selected microphone"
            return "\(name) isn't responding — its driver may still be starting up. Try again in a few seconds."
        }
    }

    /// What a mic-device lookup means for the bind about to happen.
    enum MicTargetDecision: Sendable, Equatable {
        /// Bind this device (nil = let the engine take the system default).
        case bind(AudioDeviceID?)
        /// The selection is genuinely absent: bind the system default for this
        /// session and say so.
        case useSystemDefault
        /// The HAL never answered. Substituting any device here would aim at
        /// the wedge itself.
        case abort
    }

    /// Pure policy for turning a mic-device lookup into an action, shared by
    /// `start()` and `restartMic`.
    ///
    /// The load-bearing line is the last one: `.unavailable` (no answer from
    /// the HAL) must never collapse into `.answered(nil)` (no such device).
    /// They did collapse, through `deviceID(forUID:)`'s `AudioDeviceID?`
    /// return, and that is what made one wedged bind cascade on 2026-07-27 —
    /// the next start read the refused lookup as "your microphone is gone",
    /// announced it was recording from the system default, and bound the
    /// default, which was the same device that had just wedged.
    ///
    /// When `selectedUID` is empty the caller passes the DEFAULT-device lookup;
    /// there is no selection to be absent, so a nil answer is just "no default".
    nonisolated static func resolveMicTarget(
        selectedUID: String,
        selectionLookup: HALQueryResult<AudioDeviceID?>
    ) -> MicTargetDecision {
        switch selectionLookup {
        case .unavailable:
            return .abort
        case .answered(let resolved):
            if selectedUID.isEmpty { return .bind(resolved) }
            guard let resolved else { return .useSystemDefault }
            return .bind(resolved)
        }
    }

    /// Pure policy (2026-07-25 hang spec, Part C): after a failed mic bind,
    /// may we retry once against the system default? Only for a clean setup
    /// failure. A timed-out or wedged bind means the HAL itself is stuck —
    /// the system default is usually the SAME wedged device, and a retry
    /// would just queue behind the block and time out too.
    nonisolated static func shouldAttemptDefaultFallback(after error: CaptureBindError) -> Bool {
        if case .setupFailed = error { return true }
        return false
    }

    /// Diagnostic detail for a failed device-leg bind (the user-facing story
    /// there is the SCK fallback banner, so this only feeds `lastError`/logs).
    nonisolated static func bindFailureDetail(_ error: CaptureBindError) -> String {
        switch error {
        case .setupFailed(let message):
            return message
        case .timedOut:
            return "the device didn't respond within the bind deadline (its driver may still be starting up)"
        case .halWedged:
            return "the audio system is still waiting on an earlier unresponsive device call"
        }
    }

    /// User-facing text for a mic that is delivering exact digital zeros,
    /// routed on the feeder verdict. Unfed is a certainty (known mixer device,
    /// mixer not running) and says exactly what to do; anything else keeps the
    /// hedged wording. Pure so the wording is unit-testable.
    nonisolated static func micSilenceText(deviceName: String?, verdict: FeederVerdict) -> String {
        let name = deviceName ?? "The selected microphone"
        switch verdict {
        case .unfed(let mixer):
            return "\(mixer) isn't running — your microphone \u{201C}\(name)\u{201D} is one of its devices and has nothing feeding it. Launch \(mixer), or pick a different microphone in Settings."
        case .fed, .unknown:
            return "\(name) is delivering silence — it may be muted, or the app that provides it (e.g. Wave Link) may not be running."
        }
    }

    /// The neutral hint for a muted-but-fed mic. Never routed to `lastError`.
    nonisolated static let micSilenceHintText = "Microphone is muted or silent."

    /// Device-leg counterpart of `micSilenceText`, same routing rule.
    nonisolated static func systemDeviceSilenceText(deviceName: String?, verdict: FeederVerdict) -> String {
        let name = deviceName.map { "\u{201C}\($0)\u{201D}" } ?? "The selected call audio device"
        switch verdict {
        case .unfed(let mixer):
            return "\(mixer) isn't running — call audio device \(name) is registered but unfed. Launch \(mixer) to capture the call."
        case .fed, .unknown:
            return "Call audio device \(name) is delivering silence. The app that provides it (e.g. Wave Link) may not be running, or the mix may be empty."
        }
    }

    /// Feeder verdict for a device, judged against the live process table.
    private func feederVerdict(forDeviceName name: String?) -> FeederVerdict {
        FeederDetection.verdict(
            deviceName: name,
            runningBundleIDs: MixerLeanInPrompt.runningApplicationBundleIDs()
        )
    }

    /// Bring the system ("Them") leg up for the current session and return its
    /// buffer stream, or nil if no leg could be established. Used by both
    /// `start()` and `restartSystemAudioLeg`, so a rebuild re-resolves the source
    /// from scratch: a device absent at start is adopted at the next rebuild
    /// (the device-list listener fires one when the device reappears), and a
    /// device that vanishes mid-session falls back to SCK — both surfaced.
    ///
    /// `isRebuild` marks a mid-session re-entry: a WAV already at the session
    /// path is THIS session's earlier audio (possibly the other source's), so a
    /// device bind appends to it instead of rotating it aside. `inheritedAnchor`
    /// is the pre-teardown `systemFirstSampleTime` — an adopted WAV still starts
    /// at the original source's first sample, and the post-session mixer must
    /// keep aligning it there.
    @MainActor
    private func bringUpSystemLeg(
        recordingContext: SessionRecordingContext?,
        isRebuild: Bool = false,
        inheritedAnchor: Date? = nil
    ) async -> AsyncStream<AVAudioPCMBuffer>? {
        let resolution = Self.resolveSystemSource(
            uid: activeSystemSourceUID,
            resolvedDeviceID: await MicCapture.deviceID(forUID: activeSystemSourceUID),
            micDeviceID: currentMicDeviceID
        )
        switch resolution {
        case .device(let deviceID):
            if let stream = await startDeviceSystemLeg(
                deviceID: deviceID,
                recordingContext: recordingContext,
                adoptExistingRecording: isRebuild,
                inheritedAnchor: inheritedAnchor
            ) {
                return stream
            }
            // A bind failure fails the LEG, not the session (same as an SCK
            // bring-up failure today): report it and try automatic mode so the
            // far end is still captured. This holds for a timed-out bind too —
            // SCK touches no HAL input device, so it is unaffected by a wedge.
            await reportSystemSourceFallback(reason: .bindFailed, deviceID: deviceID)
            let stream = await startSCKSystemLeg(recordingContext: recordingContext)
            // The fallback SUCCEEDED: the red bind-failure error would sit next
            // to the fallback banner all session implying nothing is recording.
            // Only our own message is wiped — a newer, unrelated error stays.
            if stream != nil, let failMsg = systemDeviceBindFailureMessage, lastError == failMsg {
                lastError = nil
            }
            systemDeviceBindFailureMessage = nil
            return stream
        case .sckFallback(let reason):
            await reportSystemSourceFallback(reason: reason, deviceID: nil)
            return await startSCKSystemLeg(recordingContext: recordingContext)
        case .sck:
            return await startSCKSystemLeg(recordingContext: recordingContext)
        }
    }

    /// Device-backed system leg: bind the mixer's virtual input device through
    /// `systemDeviceCapture`. Synchronous — `MicCapture.bufferStream` runs its
    /// setup inline, so a bind failure is already in `captureError` on return.
    ///
    /// `adoptExistingRecording` / `inheritedAnchor`: see `bringUpSystemLeg` —
    /// a rebuild appends to the session WAV (even one the SCK leg started) and
    /// back-dates the mixer-alignment anchor to the original first sample.
    @MainActor
    private func startDeviceSystemLeg(
        deviceID: AudioDeviceID,
        recordingContext: SessionRecordingContext?,
        adoptExistingRecording: Bool = false,
        inheritedAnchor: Date? = nil
    ) async -> AsyncStream<AVAudioPCMBuffer>? {
        let name = await MicCapture.deviceName(for: deviceID) ?? "?"
        diagLog("[ENGINE-4] starting call-audio capture from input device \(deviceID) \"\(name)\"")

        // Same path the SCK leg writes, so PostProcessingJob, retention mixing,
        // stem-pairing and cleanupBufferFile are all unchanged by this mode.
        let bufferURL: URL
        if let ctx = recordingContext, let dir = try? SystemAudioCapture.sessionsDirectory() {
            bufferURL = dir.appendingPathComponent("\(ctx.sessionId).wav")
            // The SCK path emits its crash-recovery sidecar inside
            // SystemAudioCapture.bufferStream; device mode has no equivalent hook,
            // so emit here — before the first audio byte — mirroring the mic-only
            // emission in start(). Nominal rate; recovery reads the WAV header.
            SessionSidecar.emit(forWAV: bufferURL, context: ctx, sampleRate: 48_000)
        } else {
            bufferURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tome_sys_audio_\(UUID().uuidString).wav")
        }
        // Snapshot before the bind creates the file: on a failed bind this
        // decides whether the artifacts are junk from THIS attempt (safe to
        // remove) or a file holding earlier session audio (must stay).
        let wavPreExisted = FileManager.default.fileExists(atPath: bufferURL.path)

        // A virtual device disappearing (mixer app quit/relaunch) produces exactly
        // the route/graph change this notification reports.
        systemDeviceCapture.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.scheduleSystemDeviceRebuild(reason: "engine configuration change") }
        }

        let bind = await systemDeviceCapture.bufferStream(
            deviceID: deviceID,
            recordOutputURL: bufferURL,
            adoptExistingRecording: adoptExistingRecording
        )
        let stream: AsyncStream<AVAudioPCMBuffer>
        switch bind {
        case .success(let boundStream):
            stream = boundStream
        case .failure(let bindError):
            let msg = "Call audio device failed: \(Self.bindFailureDetail(bindError))"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            // Remembered so a SUCCESSFUL SCK fallback can retire this error —
            // and only this error — instead of leaving a red banner up all
            // session next to a fallback banner saying capture is fine.
            systemDeviceBindFailureMessage = msg
            // Timed-out/wedged binds belong to the abandoned-op handler; only
            // a clean setup failure gets the normal teardown.
            if case .setupFailed = bindError {
                await systemDeviceCapture.stop()
            }
            // No audio was ever delivered — remove the just-provisioned
            // artifacts (header-only WAV + sidecar) so they don't accumulate as
            // sub-threshold junk, mirroring the mic-leg start failure. Only when
            // the WAV didn't pre-exist: a pre-existing file holds this session's
            // earlier audio (deleting an unlinked file a wedged bind still has
            // open is safe — its late writes land in the unlinked inode).
            if !wavPreExisted {
                try? FileManager.default.removeItem(at: bufferURL)
                SessionSidecar.deleteIfExists(forWAV: bufferURL)
            }
            return nil
        }

        systemSourceMode = .device(deviceID)
        currentBufferURL = bufferURL
        // An adopted WAV starts at the ORIGINAL source's first sample; keep the
        // post-session mixer aligned there (no-op for device→device rebuilds,
        // where the preserved anchor is already the earlier one).
        if adoptExistingRecording, wavPreExisted, let inheritedAnchor {
            systemDeviceCapture.seedFirstSampleTime(inheritedAnchor)
        }
        // A rebuild that landed back on the device retires the fallback banner.
        clearSystemSourceFallback()
        systemDeviceBindFailureMessage = nil
        armSystemDeviceDigitalSilenceCheck(deviceID: deviceID)
        diagLog("[ENGINE-5] call-audio device capture started OK (\(bufferURL.lastPathComponent))")
        return stream
    }

    /// The exact `lastError` posted by the most recent failed device-leg bind,
    /// so the SCK-fallback success path can retire it without touching a newer,
    /// unrelated error (same pattern as `micSilenceMessage`).
    private var systemDeviceBindFailureMessage: String?

    /// Automatic (ScreenCaptureKit) system leg — today's default path, unchanged.
    ///
    /// NOTE on the WAV: `SystemAudioCapture` always (re)creates its writer, so an
    /// SCK bring-up rotates whatever is at `<sessionId>.wav` aside (`.pre-<ts>.wav`
    /// — preserved on disk but outside diarization and the retained mix). That is
    /// the pre-existing behavior of every SCK rebuild, including a device-mode
    /// session that loses its device entirely and falls back here. The reverse
    /// direction does better: a rebuild that moves the leg from SCK onto the
    /// device APPENDS to the SCK-written WAV (`adoptExistingRecording`), so an
    /// adoption loses nothing. The live transcript is unaffected either way (it
    /// is written per-utterance), and the most common device failure — the mixer
    /// app quitting while its device stays registered — keeps resolving to the
    /// device and appends.
    @MainActor
    private func startSCKSystemLeg(recordingContext: SessionRecordingContext?) async -> AsyncStream<AVAudioPCMBuffer>? {
        diagLog("[ENGINE-4] starting system audio capture (automatic / ScreenCaptureKit)...")
        // Warn-only router-signature diagnostic: a process running mic input
        // AND audio output that is NOT excluded may be an audio router about
        // to bleed the user's own voice onto this leg. Never auto-excluded —
        // a conferencing app in a live call has the identical signature.
        // Deliberately skipped in device mode (where this never runs): there a
        // running router is not a hazard, it IS the source.
        let unexcludedPassthrough = AudioProcessInspector.micPassthroughBundleIDs(
            excluding: Set(activeExcludedAudioAppIDs + [Bundle.main.bundleIdentifier ?? ""])
        )
        if !unexcludedPassthrough.isEmpty {
            diagLog("[SYS-CAPTURE] mic-passthrough processes NOT excluded from capture: \(unexcludedPassthrough.joined(separator: ", ")) — if one is an audio router, own voice may appear as Them (fix: point the call audio source at one of its mixes, Settings ▸ Audio ▸ System Audio)")
        }
        do {
            let streams = try await systemCapture.bufferStream(
                recordingContext: recordingContext,
                excludedBundleIDs: activeExcludedAudioAppIDs
            )
            systemSourceMode = .sck
            currentBufferURL = streams.bufferURL
            // Any device-leg warnings describe a source we're no longer using.
            systemDeviceSilenceCheckTask?.cancel()
            systemDeviceSilenceCheckTask = nil
            clearSystemDeviceSilenceWarning()
            diagLog("[ENGINE-5] system audio capture started OK")
            return streams.systemAudio
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            return nil
        }
    }

    /// Surface a call-audio source fallback: the session is configured for a
    /// device but is recording via SCK. Banner + one notification per session,
    /// same discipline as `reportMicFallback` — a session recording from the
    /// "wrong" source must never be silent (the 2026-07-24 Part D lesson).
    @MainActor
    private func reportSystemSourceFallback(reason: SystemSourceFallbackReason, deviceID: AudioDeviceID?) async {
        var name: String?
        if let deviceID {
            name = await MicCapture.deviceName(for: deviceID)
        }
        if name == nil, let resolved = await MicCapture.deviceID(forUID: activeSystemSourceUID) {
            name = await MicCapture.deviceName(for: resolved)
        }
        // Preflight never prompts (same guard MeetingDetector uses); it only
        // decides whether to warn that the SCK fallback will.
        let msg = Self.systemSourceFallbackText(
            reason: reason,
            deviceName: name,
            mayPromptForScreenRecording: !CGPreflightScreenCaptureAccess()
        )
        guard systemSourceFallbackMessage != msg else { return }
        let isFirst = systemSourceFallbackMessage == nil
        systemSourceFallbackMessage = msg
        diagLog("[SYS-SOURCE-FALLBACK] \(msg)")
        guard isFirst else { return }
        Task { await NotificationPresenter.shared.postSystemSourceFallback(detail: msg) }
    }

    @MainActor
    private func clearSystemSourceFallback() {
        guard systemSourceFallbackMessage != nil else { return }
        systemSourceFallbackMessage = nil
        NotificationPresenter.shared.clearSystemSourceFallback()
        diagLog("[SYS-SOURCE-FALLBACK] cleared — the call audio device is in use")
    }

    /// The exact digital-silence message posted for the device leg, so the clear
    /// path only wipes `lastError` while it still shows OUR warning.
    private var systemDeviceSilenceMessage: String?

    /// One-shot handle for the device leg's digital-silence check.
    private var systemDeviceSilenceCheckTask: Task<Void, Never>?

    /// Device-mode analogue of `armMicDigitalSilenceCheck`, and this mode's
    /// PRIMARY failure detector: a mixer's virtual device stays registered in
    /// CoreAudio while its app is closed and then delivers pure digital zeros, so
    /// nothing else — not the delivery gates, not the stall watchdog — can tell
    /// "unfed mix" from "quiet call". Sample content can't either: a mix
    /// carrying only app channels (the recommended Transcriber setup) is exact
    /// zeros until the far end speaks, so every pre-join session used to warn
    /// at +5s (2026-07-25 false positive). The verdict now comes from the
    /// process table (`FeederDetection`): known-mixer device with the mixer
    /// not running = unfed, warned at bind time (0s) with certainty; a fed
    /// device's zeros are a quiet call and never warn; only devices we can't
    /// attribute wait out the 5s deadline and keep the hedged wording.
    private func armSystemDeviceDigitalSilenceCheck(deviceID: AudioDeviceID) {
        systemDeviceSilenceCheckTask?.cancel()
        systemDeviceQuietLogged = false
        let generation = sessionGeneration
        systemDeviceSilenceCheckTask = Task { [weak self] in
            // Bind-time feeder check: an unfed device is detectable NOW,
            // before any audio arrives. Fed/unknown must wait for the
            // deadline — silence isn't evidence yet.
            if let self {
                let name = await MicCapture.deviceName(for: deviceID)
                if case .unfed = self.feederVerdict(forDeviceName: name) {
                    await self.routeSystemDeviceSilence(deviceID: deviceID)
                }
            }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.sessionGeneration, self.isRunning else { return }
            guard self.systemSourceMode.isDevice else {
                self.clearSystemDeviceSilenceWarning()
                return
            }
            if self.systemDeviceCapture.sawNonzeroSample {
                // Healthy — also retires a bind-time unfed warning that healed
                // (the mixer launched inside the window).
                self.clearSystemDeviceSilenceWarning()
                return
            }
            if self.systemDeviceCapture.firstSampleTime == nil, self.systemDeviceSilenceMessage == nil {
                // Not delivering at all — the delivery gates own that. (With an
                // unfed warning posted, keep it: it explains WHY nothing flows.)
                self.clearSystemDeviceSilenceWarning()
                return
            }
            await self.routeSystemDeviceSilence(deviceID: deviceID)
            // Monitor: real audio clears everything; otherwise re-evaluate the
            // feeder each tick, so a mixer quitting mid-call warns within ~5s
            // and a relaunch retires the warning.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard generation == self.sessionGeneration, self.isRunning else { return }
                // A rebuild may have fallen back to SCK since we armed; the
                // warning is about a device that is no longer the source.
                guard self.systemSourceMode.isDevice else {
                    self.clearSystemDeviceSilenceWarning()
                    return
                }
                if self.systemDeviceCapture.sawNonzeroSample {
                    diagLog("[SYS-DEVICE-SILENCE] real audio arrived — clearing the silence warning")
                    self.clearSystemDeviceSilenceWarning()
                    return
                }
                await self.routeSystemDeviceSilence(deviceID: deviceID)
            }
        }
    }

    /// True once the fed-but-quiet state has been diag-logged this arming —
    /// the monitor re-routes every 5s and must not spam the log store.
    private var systemDeviceQuietLogged = false

    /// Post whatever the current feeder verdict calls for, idempotently.
    /// `.fed` + zeros is a quiet call — normal, never a banner; it also
    /// retires an unfed warning whose mixer has come back.
    private func routeSystemDeviceSilence(deviceID: AudioDeviceID) async {
        let name = await MicCapture.deviceName(for: deviceID)
        let verdict = feederVerdict(forDeviceName: name)
        switch verdict {
        case .fed:
            if systemDeviceSilenceMessage != nil {
                diagLog("[SYS-DEVICE-SILENCE] feeder is running again — retiring the unfed warning")
                clearSystemDeviceSilenceWarning()
            } else if !systemDeviceQuietLogged {
                systemDeviceQuietLogged = true
                diagLog("[SYS-DEVICE-SILENCE] digital zeros with the mixer running — quiet call, no warning")
            }
        case .unfed, .unknown:
            let msg = Self.systemDeviceSilenceText(deviceName: name, verdict: verdict)
            guard systemDeviceSilenceMessage != msg else { return }
            diagLog("[SYS-DEVICE-SILENCE] \(msg)")
            systemDeviceSilenceMessage = msg
            lastError = msg
            Task { await NotificationPresenter.shared.postSystemSourceSilence(detail: msg) }
        }
    }

    private func clearSystemDeviceSilenceWarning() {
        guard let msg = systemDeviceSilenceMessage else { return }
        systemDeviceSilenceMessage = nil
        if lastError == msg { lastError = nil }
        NotificationPresenter.shared.clearSystemSourceSilence()
    }

    /// Timestamps of recent config-driven device-leg rebuilds — loop suppression.
    private var recentSystemDeviceRebuilds: [Date] = []

    /// Debounced rebuild of the DEVICE-backed system leg, fired by that capture's
    /// `AVAudioEngineConfigurationChange` / HAL fast path. Mirrors
    /// `scheduleMicRebuild` gate for gate — ground truth (a tap that delivered
    /// within 2s is alive, the notification was informational), first-delivery
    /// grace (our own rebuild's HAL echo must not trigger a second one), and the
    /// 4-per-minute storm cap that hands recovery back to the stall watchdog.
    private func scheduleSystemDeviceRebuild(reason: String) {
        guard isRunning, systemSourceMode.isDevice else { return }
        systemDeviceRebuildTask?.cancel()
        systemDeviceRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            guard let self, self.isRunning, self.systemSourceMode.isDevice else { return }

            if let last = self.systemDeviceCapture.lastSampleTime,
               Date().timeIntervalSince(last) < 2.0 {
                diagLog("[ENGINE-SYSDEV-REBUILD] skipped (\(reason)) — tap is delivering")
                return
            }
            if self.systemDeviceCapture.firstSampleTime == nil,
               let started = self.systemDeviceCapture.captureStartTime {
                let age = Date().timeIntervalSince(started)
                if age < 2.0 {
                    diagLog("[ENGINE-SYSDEV-REBUILD] skipped — capture just (re)started \(age)s ago, giving the tap time to first-deliver")
                    return
                }
            }
            let now = Date()
            self.recentSystemDeviceRebuilds.removeAll { now.timeIntervalSince($0) > 60 }
            guard self.recentSystemDeviceRebuilds.count < 4 else {
                diagLog("[ENGINE-SYSDEV-REBUILD] suppressed (\(reason)) — \(self.recentSystemDeviceRebuilds.count) rebuilds in 60s; deferring to the watchdog")
                return
            }
            self.recentSystemDeviceRebuilds.append(now)

            diagLog("[ENGINE-SYSDEV-REBUILD] \(reason) — rebuilding the call-audio device leg")
            await self.restartSystemAudioLeg()
        }
    }

    private var systemDeviceRebuildTask: Task<Void, Never>?

    /// Arm the one-shot system-audio startup-delivery gate. Mirrors
    /// `armStartupDeliveryGate` (the mic side) but for the SCStream leg: if no
    /// sample arrives within the window, rebuild the leg ONCE. The window is longer
    /// than the mic's 3s because ScreenCaptureKit's first-sample latency is higher
    /// (shareable-content query + stream negotiation). Timeline note: the rebuild
    /// re-seeds the stall watchdog's clock, so the watchdog alone wouldn't alarm on
    /// a rebuilt-but-still-silent leg until ~15s post-rebuild — the +5s grace check
    /// armed by `restartSystemAudioLeg` owns that alarm instead.
    private func armSystemStartupDeliveryGate() {
        sysStartupGateTask?.cancel()
        sysStartupGateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.handleSystemStartupGate()
        }
    }

    /// Fire-time decision + action for the system-audio startup gate. Same pure
    /// predicate as the mic gate: rebuild only when the engine is still running,
    /// the leg has NEVER delivered a sample this session (`firstSampleTime == nil`
    /// — distinct from delivered-then-paused, which is the watchdog's job), the
    /// gate hasn't already fired, and no rebuild is already in flight.
    @MainActor
    private func handleSystemStartupGate() async {
        guard Self.shouldForceStartupRestart(
                  firstSampleAt: systemLegSampleSinceBind,
                  isRunning: isRunning,
                  alreadyFired: sysStartupGateFired,
                  rebuildInFlight: sysRebuildInFlight
              )
        else { return }
        sysStartupGateFired = true
        diagLog("[SYS-STARTGATE] no system-audio sample within 8s — rebuilding the system leg once")
        await restartSystemAudioLeg()
    }

    /// True between `restartSystemAudioLeg` entry and exit. With both the startup
    /// gate and the watchdog able to trigger rebuilds, this stops a second rebuild
    /// from tearing down the one still coming up.
    private var sysRebuildInFlight = false

    /// Tear down and re-establish the system-audio leg on the current session.
    /// Reuses the retained recording context so the rebuilt WAV keeps the same
    /// session identity/path. If the rebuild itself fails to come up, surface it —
    /// a persistent zero-delivery is a permission/routing problem a further retry
    /// won't fix. A rebuild that SUCCEEDS but stays silent is caught by the +5s
    /// grace check armed below (the watchdog's re-seeded clock is too slow — see
    /// `sysRebuildGraceTask`).
    @MainActor
    private func restartSystemAudioLeg() async {
        guard isRunning, let vadManager, !sysRebuildInFlight else { return }
        sysRebuildInFlight = true
        defer { sysRebuildInFlight = false }
        // Staleness token: `isRunning` is NOT sufficient across the awaits below —
        // stop() keeps it true until after its (up to 15s) transcriber drain, and a
        // stop-then-quick-restart flips it back to true for a DIFFERENT session.
        // Re-check the generation after every suspension.
        let generation = sessionGeneration
        sysTask?.cancel()
        sysTask = nil
        // Snapshot the session's system-track anchor BEFORE teardown: SCK
        // resets `firstSampleTime` on stop(), and if this rebuild adopts the
        // configured device (SCK→device), the appended WAV still starts at the
        // original source's first sample — the post-session mixer must keep
        // aligning it there, not at the adoption moment.
        let previousAnchor = systemFirstSampleTime
        // Tear both sources down: the rebuild re-resolves the source from
        // scratch, so it may come back up on the OTHER one (device gone → SCK,
        // device returned → device). Stopping an already-stopped capture is a
        // cheap no-op.
        await systemCapture.stop()
        await systemDeviceCapture.stop()
        guard generation == sessionGeneration, isRunning else { return }

        // Rebuilds re-enter with the SAME recordOutputURL and `isRebuild: true`,
        // so a device bind appends to the session WAV — everything captured
        // before the interruption (by either source) stays in the file.
        let stream = await bringUpSystemLeg(
            recordingContext: activeRecordingContext,
            isRebuild: true,
            inheritedAnchor: previousAnchor
        )
        guard generation == sessionGeneration, isRunning else {
            // Stale: a stop (or a new session's start) raced the bring-up.
            // Unwind the capture we just started so it can't leak an SCStream
            // and an orphaned $TMPDIR WAV into whatever session runs next.
            await systemCapture.stop()
            await systemDeviceCapture.stop()
            return
        }
        guard let stream else {
            let msg = "System audio isn't being captured — recording mic only."
            diagLog("[SYS-STARTGATE] rebuild failed to bring up any system source")
            lastError = msg
            Task { await NotificationPresenter.shared.postCaptureStall(leg: "System audio", detail: msg) }
            return
        }
        spinUpSystemTranscription(stream: stream, vadManager: vadManager)
        diagLog("[SYS-STARTGATE] system leg rebuilt")
        armSystemRebuildGraceCheck(generation: generation)
    }

    /// Arm the +5s post-rebuild grace check: if the just-rebuilt system leg never
    /// delivers a first sample, alarm directly with the same message/notification
    /// as a failed rebuild. `firstSampleTime` was reset by the rebuild's
    /// `systemCapture.stop()`, so nil here means the NEW stream stayed silent —
    /// distinct from delivered-then-paused (still the watchdog's job). Respects the
    /// session-generation guard so a stop or stop-then-restart makes it a no-op.
    private func armSystemRebuildGraceCheck(generation: Int) {
        sysRebuildGraceTask?.cancel()
        sysRebuildGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.sessionGeneration, self.isRunning else { return }
            guard self.systemLegSampleSinceBind == nil else { return }  // delivered — healthy
            let msg = "System audio isn't being captured — recording mic only."
            diagLog("[SYS-STARTGATE] rebuilt system leg still silent after 5s — alerting")
            self.lastError = msg
            Task { await NotificationPresenter.shared.postCaptureStall(leg: "System audio", detail: msg) }
        }
    }

    /// Pure decision shared by BOTH startup-delivery gates (mic below, system in
    /// `handleSystemStartupGate`). Extracted so the never-delivered-vs-delivered
    /// distinction and the strict one-shot rule can be unit-tested without audio
    /// hardware. Force a single restart only when the engine is still running,
    /// the leg has NEVER delivered a sample this session (`firstSampleAt == nil`
    /// — distinct from delivered-then-quiet, which is the watchdog's job), the
    /// gate hasn't already fired, and no rebuild is already in flight (mic: the
    /// debounced config/HAL rebuild; system: `sysRebuildInFlight`) — that rebuild
    /// re-opens the leg on its own, don't stack a second restart on top.
    /// Pure decision for post-bind fallback reconciliation (see `restartMic`):
    /// capture counts as "fallen back" only when the user pinned a specific
    /// device (non-empty UID) and the device we actually bound is not the one
    /// that UID currently resolves to (including resolving to nothing at all).
    /// System Default selection can never be a fallback. Extracted for
    /// unit-testing without audio hardware, like `shouldForceStartupRestart`.
    nonisolated static func isMicFallbackActive(
        selectedUID: String,
        selectionResolvesTo: AudioDeviceID?,
        boundDeviceID: AudioDeviceID
    ) -> Bool {
        guard !selectedUID.isEmpty else { return false }
        return selectionResolvesTo != boundDeviceID
    }

    nonisolated static func shouldForceStartupRestart(
        firstSampleAt: Date?,
        isRunning: Bool,
        alreadyFired: Bool,
        rebuildInFlight: Bool
    ) -> Bool {
        isRunning && firstSampleAt == nil && !alreadyFired && !rebuildInFlight
    }

    /// Arm the one-shot startup-delivery gate: a silent fast retry for the
    /// AirPods cold-start silence bug. `bufferStream`'s HAL fast path is the
    /// primary catch, but if the A2DP→HFP flip races even that (or macOS doesn't
    /// post the HAL change for this particular mutation), only the 15s stall
    /// watchdog would rescue it — 15–22s of lost audio every AirPods recording.
    /// This collapses that to ~3s.
    ///
    /// Strictly one-shot per `start()`: if the forced restart doesn't help, the
    /// watchdog remains the net; we do NOT loop. The never-delivered condition is
    /// re-checked at FIRE time (not cancelled on delivery) so natural first
    /// delivery just makes it a no-op — `firstSampleTime` stays nil only when the
    /// tap truly never fired, distinct from delivered-then-quiet (the watchdog's
    /// domain). This is a silent retry: NO user-facing stall notification, unlike
    /// the watchdog's alarm.
    private func armStartupDeliveryGate() {
        startupGateTask?.cancel()
        startupGateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // The rebuild-in-flight check is folded into the pure gate: a
                // debounced config/HAL rebuild already pending will re-open the
                // mic on its own — don't stack a second restart on top.
                guard Self.shouldForceStartupRestart(
                          firstSampleAt: self.micCapture.firstSampleTime,
                          isRunning: self.isRunning,
                          alreadyFired: self.startupGateFired,
                          rebuildInFlight: self.micRebuildTask != nil
                      )
                else { return }

                self.startupGateFired = true
                diagLog("[MIC-STARTGATE] no first sample within 3s of start — forcing one mic restart")
                // Same restart path the watchdog uses, WITHOUT the user-facing
                // stall notification: this is a silent fast retry, not an alarm.
                // `silent: true` also suppresses the bind-failure fallback's
                // postCaptureStall/lastError — a failed silent retry leaves the
                // rescue to the stall watchdog rather than alarming the user.
                Task { await self.restartMic(inputDeviceUID: self.userSelectedDeviceUID, force: true, silent: true) }
            }
        }
    }

    /// Unwind a start that never got as far as a bind because the HAL wouldn't
    /// answer which device to bind. Same user-facing wording as a timed-out
    /// bind — from the user's seat it is the same event, and the advice ("try
    /// again in a few seconds") is the same. Deliberately NOT a mic-fallback:
    /// nothing is recording, and no substitute device was chosen.
    private func failStartWithUnresponsiveHAL(deviceName: String?) {
        let msg = Self.micBindFailureText(error: .halWedged, deviceName: deviceName)
        diagLog("[ENGINE-3-FAIL] mic device resolution refused — the HAL is unresponsive; not substituting a device")
        lastError = msg
        clearMicFallback()
        assetStatus = "Ready"
        isRunning = false
        endLiveActivity()
    }

    /// Surface a mic fallback: capture is running on `boundDeviceID` instead of
    /// the user's selection. Banner (via `micFallbackMessage`) + one notification
    /// — the Tome window is typically hidden behind the meeting app when this
    /// matters. Guarded against re-posting on every watchdog retry.
    private func reportMicFallback(boundDeviceID: AudioDeviceID?) async {
        guard micFallbackMessage == nil else { return }
        var boundName: String?
        if let boundDeviceID { boundName = await MicCapture.deviceName(for: boundDeviceID) }
        let actual = boundName ?? "the system default microphone"
        let msg = "Selected mic unavailable — recording from \(actual). Your Settings choice is unchanged."
        micFallbackMessage = msg
        diagLog("[MIC-FALLBACK] \(msg)")
        Task { await NotificationPresenter.shared.postMicFallback(detail: msg) }
    }

    /// Clear fallback state after a bind landed back on the user's selection
    /// (or the selection is System Default, where "fallback" has no meaning).
    private func clearMicFallback() {
        guard micFallbackMessage != nil else { return }
        micFallbackMessage = nil
        NotificationPresenter.shared.clearMicFallback()
        diagLog("[MIC-FALLBACK] cleared — capture is back on the selected device")
    }

    /// One-shot at +8s, then a monitor: if the mic tap is DELIVERING buffers
    /// but every sample so far is exactly zero, decide what that means — and
    /// exact zeros alone are NOT a fault (2026-07-25 false positive: a Wave
    /// Link mute renders exact zeros into a fed mic mix, so "muted at the top
    /// of a call" red-bannered a healthy session at +8s). Routing is by
    /// feeder verdict: a known mixer's device with the mixer not running is
    /// unfed — warned at bind time (0s), no zeros needed as proof; a fed
    /// device's zeros are a muted mic — neutral hint, never `lastError`;
    /// only unattributable devices keep the old hedged warning at the
    /// deadline. The monitor clears everything when real audio arrives, and
    /// re-evaluates the feeder each tick so a mixer quitting mid-session
    /// escalates the hint to a warning (and a relaunch softens it back).
    private func armMicDigitalSilenceCheck() {
        micSilenceCheckTask?.cancel()
        let generation = sessionGeneration
        micSilenceCheckTask = Task { [weak self] in
            // Bind-time feeder check: unfed is knowable NOW, from the process
            // table. Fed/unknown wait — silence isn't evidence yet.
            if let self {
                let name = await MicCapture.deviceName(for: self.currentMicDeviceID)
                let verdict = self.feederVerdict(forDeviceName: name)
                if case .unfed = verdict {
                    self.postMicSilenceWarning(Self.micSilenceText(deviceName: name, verdict: verdict))
                }
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.sessionGeneration, self.isRunning else { return }
            if self.micCapture.sawNonzeroSample {
                // Healthy — retires a bind-time unfed warning that healed, and
                // a previous device's still-posted warning is stale now too.
                self.clearMicSilenceWarning()
                return
            }
            if self.micCapture.firstSampleTime == nil, self.micSilenceMessage == nil {
                // Not delivering at all — the delivery gates own that. (With an
                // unfed warning posted, keep it: it explains WHY nothing flows.)
                self.clearMicSilenceWarning()
                return
            }
            await self.routeMicSilence()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard generation == self.sessionGeneration, self.isRunning else { return }
                if self.micCapture.sawNonzeroSample {
                    diagLog("[MIC-SILENCE] real audio arrived — clearing the silence warning")
                    self.clearMicSilenceWarning()
                    return
                }
                await self.routeMicSilence()
            }
        }
    }

    /// Post whatever the current feeder verdict calls for, idempotently —
    /// called at the deadline and on every monitor tick while zeros persist.
    private func routeMicSilence() async {
        let name = await MicCapture.deviceName(for: currentMicDeviceID)
        let verdict = feederVerdict(forDeviceName: name)
        switch verdict {
        case .fed:
            postMicSilenceHint()
        case .unfed, .unknown:
            postMicSilenceWarning(Self.micSilenceText(deviceName: name, verdict: verdict))
        }
    }

    private func postMicSilenceWarning(_ msg: String) {
        micSilenceHintMessage = nil
        guard micSilenceMessage != msg else { return }
        diagLog("[MIC-SILENCE] \(msg)")
        micSilenceMessage = msg
        lastError = msg
        Task { await NotificationPresenter.shared.postMicDigitalSilence(detail: msg) }
    }

    /// The fed-but-zeros state: the mic is muted, which is user intent, not a
    /// fault. Neutral gray line, no `lastError`, no notification. Softens a
    /// prior unfed warning whose mixer has come back but stays muted.
    private func postMicSilenceHint() {
        if let msg = micSilenceMessage {
            micSilenceMessage = nil
            if lastError == msg { lastError = nil }
            NotificationPresenter.shared.clearMicDigitalSilence()
        }
        guard micSilenceHintMessage == nil else { return }
        micSilenceHintMessage = Self.micSilenceHintText
        diagLog("[MIC-SILENCE] digital zeros with the mic's feeder running — muted mic, neutral hint only")
    }

    /// The exact message posted by the digital-silence check, so the clear path
    /// only wipes `lastError` when it still shows OUR warning (not some newer,
    /// unrelated error).
    private var micSilenceMessage: String?

    private func clearMicSilenceWarning() {
        micSilenceHintMessage = nil
        guard let msg = micSilenceMessage else { return }
        micSilenceMessage = nil
        if lastError == msg { lastError = nil }
        NotificationPresenter.shared.clearMicDigitalSilence()
    }

    /// Timestamps of recent config-driven rebuilds — loop suppression window.
    private var recentMicRebuilds: [Date] = []

    /// Schedule a debounced mic rebuild on the CURRENT device selection. Fired by
    /// `AVAudioEngineConfigurationChange`; coalesces the notification flurries a
    /// Bluetooth transition produces into one restart after the graph settles.
    ///
    /// The notification is only a HINT: on this macOS the engine can post it
    /// after a (re)start even though capture is healthy, so an ungated rebuild
    /// tears down a working mic and re-triggers itself — observed in the field as
    /// Micro Snitch showing the mic bouncing every ~1.2s until the HAL refused
    /// further binds with 'nope'. Two gates below: ground truth (tap still
    /// delivering → never rebuild) and a rate limiter (4/minute → stand down and
    /// leave recovery to the stall watchdog).
    private func scheduleMicRebuild(reason: String) {
        guard isRunning else { return }
        micRebuildTask?.cancel()
        micRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            guard let self, self.isRunning else { return }

            // Gate 1 — ground truth: a tap that delivered within the last 2s is
            // alive; the notification was informational. Touch nothing.
            if let last = self.micCapture.lastSampleTime,
               Date().timeIntervalSince(last) < 2.0 {
                diagLog("[ENGINE-MIC-REBUILD] skipped (\(reason)) — tap is delivering")
                return
            }

            // Gate 1b — first-delivery grace: a tap we JUST (re)started that
            // hasn't delivered yet reads as dead by the check above, so our own
            // rebuild's HAL echo (the rate flip) can trigger a second rebuild —
            // a bounded-but-janky 4-flip storm. Give any fresh bring-up 2s to
            // first-deliver before we tear it down. This forecloses the echo
            // oscillation structurally: a rebuild at T reseeds captureStartTime;
            // the echo's config-change debounce expires ~T+1.3s < T+2.0s, so it
            // lands here and is skipped; if the tap then delivers, done. The true
            // never-delivers wedge is still rescued by the 3s startup gate (one-
            // shot, silent) and ultimately the 15s watchdog, so suppressing
            // rebuilds in the first 2s of a bring-up costs at most ~1-2s on the
            // HAL fast path while making the oscillation impossible.
            if self.micCapture.firstSampleTime == nil,
               let started = self.micCapture.captureStartTime {
                let age = Date().timeIntervalSince(started)
                if age < 2.0 {
                    diagLog("[ENGINE-MIC-REBUILD] skipped — capture just (re)started \(age)s ago, giving the tap time to first-deliver")
                    return
                }
            }

            // Gate 2 — loop breaker: a rebuild whose replacement also dies re-fires
            // the notification; without a cap that storm hammers the HAL. After 4
            // rebuilds in 60s, stand down — the watchdog retries on its own cadence.
            let now = Date()
            self.recentMicRebuilds.removeAll { now.timeIntervalSince($0) > 60 }
            guard self.recentMicRebuilds.count < 4 else {
                diagLog("[ENGINE-MIC-REBUILD] suppressed (\(reason)) — \(self.recentMicRebuilds.count) rebuilds in 60s; deferring to the watchdog")
                return
            }
            self.recentMicRebuilds.append(now)

            diagLog("[ENGINE-MIC-REBUILD] \(reason) — restarting mic on current selection")
            await self.restartMic(inputDeviceUID: self.userSelectedDeviceUID, force: true)
        }
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value ("" = system default, or a persisted device UID —
    /// resolved to a live AudioDeviceID here, at bind time, because numeric IDs
    /// shift across driver reloads while UIDs don't).
    /// `force` skips the same-device short-circuit — used by the capture watchdog to
    /// re-establish a mic whose tap stopped delivering on the SAME device.
    /// `updateSelection: false` marks an EMERGENCY rebind (fallback to default after
    /// a failed device bind): capture moves, but the user's intent is preserved so
    /// watchdog retries keep aiming at the chosen device until it's bindable again.
    /// `silent: true` marks a startup-gate fast retry: on bind failure it does NOT
    /// post the user-facing stall notification or set `lastError` for this attempt
    /// — the true never-delivers wedge is still owned by the stall watchdog. Any
    /// recursive fallback restart inside a silent attempt stays silent. The
    /// RESULTING fallback state (recording off a non-selected device) is surfaced
    /// even for silent attempts — only the attempt error is quiet, never the outcome.
    func restartMic(inputDeviceUID: String, force: Bool = false, updateSelection: Bool = true, silent: Bool = false) async {
        guard isRunning, let vadManager else { return }

        // Only update user selection when explicitly changed (not from OS listener,
        // not from an emergency fallback)
        if updateSelection {
            userSelectedDeviceUID = inputDeviceUID
        }
        // Same degraded-vs-absent rule as `start()`: a refused lookup must not
        // be read as "the selected device is gone". Tearing down a working mic
        // to chase the system default on the strength of an unanswered query is
        // strictly worse than keeping what we have — during a HAL wedge the
        // default is usually the wedged device, so the swap trades a live mic
        // for a dead one. Abort and leave the rescue to the stall watchdog.
        let selectionLookup = inputDeviceUID.isEmpty
            ? await MicCapture.defaultInputDeviceIDResult()
            : await MicCapture.deviceIDResult(forUID: inputDeviceUID)
        let targetMicID: AudioDeviceID
        switch Self.resolveMicTarget(selectedUID: inputDeviceUID, selectionLookup: selectionLookup) {
        case .bind(let resolved):
            targetMicID = resolved ?? 0
        case .useSystemDefault:
            // Selected device absent right now: bind the default for this
            // attempt. The fallback banner is raised by the reconciliation at
            // the end of the successful bind below.
            switch await MicCapture.defaultInputDeviceIDResult() {
            case .answered(let fallbackID): targetMicID = fallbackID ?? 0
            case .unavailable:
                diagLog("[ENGINE-MIC-SWAP-ABORT] default-device lookup refused (HAL unresponsive) — keeping the current mic")
                return
            }
        case .abort:
            diagLog("[ENGINE-MIC-SWAP-ABORT] device lookup refused (HAL unresponsive) — keeping the current mic")
            return
        }
        guard force || targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // A user/watchdog-initiated restart supersedes any pending debounced rebuild.
        // `micReadoptionTask` is deliberately NOT cancelled here: a re-adoption
        // runs `restartMic` from inside that very task, so cancelling it would
        // cancel the bind we are in the middle of. It needs no cancelling —
        // it re-reads the selection and the bound device after its debounce and
        // no-ops once capture is already on the selection.
        micRebuildTask?.cancel()
        micRebuildTask = nil

        // Tear down old mic
        micTask?.cancel()
        micTask = nil
        // Staleness token for the awaits below (stop + bind both suspend now):
        // a session stop, or a stop-then-quick-restart, must not let this
        // restart resurrect capture for a session that no longer exists.
        let generation = sessionGeneration
        await micCapture.stop()

        guard generation == sessionGeneration, isRunning else {
            diagLog("[ENGINE-MIC-SWAP-ABORT] session changed during mic teardown — abandoning restart")
            return
        }

        currentMicDeviceID = targetMicID

        // Start new mic stream. `adoptExistingRecording` reopens the retention
        // WAV in `.append` mode at the same path, so the pre-swap audio is
        // preserved (see MicCapture) — this URL is the active session's own file.
        let micBind = await micCapture.bufferStream(
            deviceID: targetMicID,
            recordOutputURL: currentMicBufferURL,
            adoptExistingRecording: true
        )

        guard generation == sessionGeneration, isRunning else {
            diagLog("[ENGINE-MIC-SWAP-ABORT] session changed during mic bind — unwinding")
            await micCapture.stop()
            return
        }

        // A failed restart means the user's side is NOT being recorded.
        // Surface loudly, and for a clean setup failure try ONE fallback to
        // the system default before giving up: a specific device refusing to
        // bind (HAL 'nope' during a Bluetooth transition, a stale id) shouldn't
        // leave the mic dead when another input would work. A timed-out or
        // wedged bind gets NO fallback (2026-07-25 spec, Part C): the default
        // is usually the same wedged device, and the retry would only queue
        // behind the block. The watchdog keeps monitoring either way.
        let micStream: AsyncStream<AVAudioPCMBuffer>
        switch micBind {
        case .success(let stream):
            micStream = stream
        case .failure(let bindError):
            let msg = "Mic restart failed: \(Self.bindFailureDetail(bindError))"
            if silent {
                // Startup-gate fast retry: no user-facing alarm for this attempt.
                // If the mic truly never binds, the stall watchdog owns the rescue.
                diagLog("[MIC-STARTGATE] silent restart failed to bind — leaving rescue to the stall watchdog")
            } else {
                lastError = msg
                diagLog("[ENGINE-MIC-SWAP-FAIL] \(msg)")
                Task { await NotificationPresenter.shared.postCaptureStall(leg: "Microphone", detail: msg) }
            }
            if Self.shouldAttemptDefaultFallback(after: bindError),
               targetMicID != 0,
               let fallback = await MicCapture.defaultInputDeviceID(), fallback != targetMicID {
                diagLog("[ENGINE-MIC-SWAP] falling back to system default input (\(fallback)) — user selection preserved")
                await restartMic(inputDeviceUID: "", force: true, updateSelection: false, silent: silent)
            }
            return
        }
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrCoordinator: asrCoordinator,
            vad: SileroVADStream(manager: vadManager),
            speaker: .you,
            audioSource: .microphone,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, startTime in
                await MainActor.run {
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you, timestamp: startTime))
                }
            }
        )
        let reportMicError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.lastError = msg }
        }
        micTask = Task.detached {
            let hadFatalError = await micTranscriber.run(stream: micStream)
            if hadFatalError {
                reportMicError("Mic transcription failed — restart session")
            }
        }

        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(targetMicID)")

        // Fallback-state reconciliation for the device we actually bound: raise
        // the banner when capture landed off the user's selection (unresolvable
        // UID, or the emergency default rebind above with the selection
        // preserved), clear it when a later rebuild lands back on it. Runs on
        // the SUCCESS path only — a failed bind changed nothing.
        // A degraded lookup can't tell us whether we landed on the selection, and
        // guessing raises "Selected mic unavailable" over a bind that just
        // succeeded. Leave the banner state untouched until a later rebuild can
        // resolve it for real.
        switch await MicCapture.deviceIDResult(forUID: userSelectedDeviceUID) {
        case .answered(let selectionResolvesTo):
            if Self.isMicFallbackActive(
                selectedUID: userSelectedDeviceUID,
                selectionResolvesTo: selectionResolvesTo,
                boundDeviceID: targetMicID
            ) {
                await reportMicFallback(boundDeviceID: targetMicID)
            } else {
                clearMicFallback()
            }
        case .unavailable:
            diagLog("[MIC-FALLBACK] reconciliation skipped — UID lookup refused (HAL unresponsive)")
        }
        // The new device must prove it delivers real audio, same as at start.
        armMicDigitalSilenceCheck()

        // The same-as-mic refusal (`resolveSystemSource`) only runs when the
        // SYSTEM leg binds — a mic restart can land on the very device serving
        // the device-backed system leg (the watchdog's surrender-to-default when
        // the OS default IS the mix device, or a live Settings change), which is
        // the exact double-transcription device mode exists to prevent. Rebuild
        // the system leg so the resolver re-runs and refuses the collision,
        // falling back to SCK with the standard banner.
        if systemSourceMode == .device(targetMicID) {
            diagLog("[ENGINE-MIC-SWAP] mic is now on the call-audio source device — rebuilding the system leg to resolve the collision")
            await restartSystemAudioLeg()
        }
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceUID.isEmpty else { return }
                // User has "System Default" selected — follow the OS default
                await self.restartMic(inputDeviceUID: "")
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    // MARK: - Device-list listener (call-audio source re-adoption)

    private static var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Installed per session, only when a call-audio source is configured (the
    /// default "" source never needs re-adoption). Registering a listener is a
    /// non-blocking CoreAudio call — same pattern as the default-device
    /// listener and the Settings picker's `InputDeviceList`.
    private func installDeviceListListener() {
        guard deviceListListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleMicSourceReadoption()
                self.scheduleDeviceSourceReadoption()
            }
        }
        deviceListListenerBlock = block
        var address = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceListListener() {
        guard let block = deviceListListenerBlock else { return }
        var address = Self.deviceListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        deviceListListenerBlock = nil
    }

    /// Debounced (2s) so the device-list storm a Bluetooth transition produces
    /// collapses into one check after the graph settles. The rebuild itself
    /// re-resolves from scratch and is generation-guarded, so the checks here
    /// are gates against pointless work, not correctness guards.
    private func scheduleDeviceSourceReadoption() {
        guard isRunning, !activeSystemSourceUID.isEmpty, !systemSourceMode.isDevice else { return }
        deviceReadoptionTask?.cancel()
        let generation = sessionGeneration
        deviceReadoptionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.sessionGeneration else { return }
            let resolution = Self.resolveSystemSource(
                uid: self.activeSystemSourceUID,
                resolvedDeviceID: await MicCapture.deviceID(forUID: self.activeSystemSourceUID),
                micDeviceID: self.currentMicDeviceID
            )
            guard generation == self.sessionGeneration,
                  Self.shouldReadoptDeviceSource(
                      isRunning: self.isRunning,
                      configuredUID: self.activeSystemSourceUID,
                      legIsOnDevice: self.systemSourceMode.isDevice,
                      resolution: resolution
                  )
            else { return }
            diagLog("[SYS-READOPT] configured call-audio device is present again — rebuilding the system leg to adopt it")
            await self.restartSystemAudioLeg()
        }
    }

    /// Mic-leg re-adoption, scheduled from the same device-list listener and
    /// debounced the same 2s: a dock event fires a storm of device-list changes
    /// while the dock's audio devices enumerate, and the pinned mic is only
    /// worth binding once the graph has settled.
    ///
    /// This is what makes a pinned microphone survive an undock: `start()` falls
    /// back to the system default and raises the banner when the pinned device
    /// is absent, and this hands capture back the moment it returns —
    /// mid-session, without the user touching Settings. `restartMic` does the
    /// rest: it appends to the same session WAV, re-runs the fallback
    /// reconciliation (which clears the banner now that we're back on the
    /// selection), re-arms the digital-silence check, and refuses a collision
    /// with the device-backed system leg.
    private func scheduleMicSourceReadoption() {
        guard isRunning, !userSelectedDeviceUID.isEmpty else { return }
        micReadoptionTask?.cancel()
        let generation = sessionGeneration
        micReadoptionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.sessionGeneration else { return }
            let selectedUID = self.userSelectedDeviceUID
            let lookup = await MicCapture.deviceIDResult(forUID: selectedUID)
            guard generation == self.sessionGeneration,
                  Self.shouldReadoptMicDevice(
                      isRunning: self.isRunning,
                      selectedUID: selectedUID,
                      currentMicDeviceID: self.currentMicDeviceID,
                      selectionLookup: lookup
                  )
            else { return }
            diagLog("[MIC-READOPT] the selected microphone is present again — restarting the mic leg to adopt it")
            // `updateSelection: false` — nothing about the user's choice changed;
            // this only moves capture back onto it.
            await self.restartMic(inputDeviceUID: selectedUID, updateSelection: false)
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func stop() async {
        // Invalidate any in-flight system-leg rebuild BEFORE the first await:
        // `isRunning` stays true until the end of this method, so the generation
        // token is what actually stops a racing `restartSystemAudioLeg` from
        // resurrecting capture mid-teardown.
        sessionGeneration += 1
        lastError = nil
        removeDefaultDeviceListener()
        removeDeviceListListener()
        deviceReadoptionTask?.cancel()
        deviceReadoptionTask = nil
        micReadoptionTask?.cancel()
        micReadoptionTask = nil
        startupGateTask?.cancel()
        startupGateTask = nil
        sysStartupGateTask?.cancel()
        sysStartupGateTask = nil
        sysRebuildGraceTask?.cancel()
        sysRebuildGraceTask = nil
        micSilenceCheckTask?.cancel()
        micSilenceCheckTask = nil
        micSilenceMessage = nil
        micSilenceHintMessage = nil
        micFallbackMessage = nil
        systemDeviceSilenceCheckTask?.cancel()
        systemDeviceSilenceCheckTask = nil
        systemDeviceSilenceMessage = nil
        systemDeviceBindFailureMessage = nil
        systemSourceFallbackMessage = nil
        NotificationPresenter.shared.clearMicDigitalSilence()
        NotificationPresenter.shared.clearMicFallback()
        NotificationPresenter.shared.clearSystemSourceSilence()
        NotificationPresenter.shared.clearSystemSourceFallback()
        activeRecordingContext = nil
        activeExcludedAudioAppIDs = []
        activeSystemSourceUID = ""
        micRebuildTask?.cancel()
        micRebuildTask = nil
        micCapture.onConfigurationChange = nil
        systemDeviceRebuildTask?.cancel()
        systemDeviceRebuildTask = nil
        systemDeviceCapture.onConfigurationChange = nil
        recentMicRebuilds = []
        recentSystemDeviceRebuilds = []
        sysWatchdogTask?.cancel()
        sysWatchdogTask = nil
        // Stop the captures FIRST — each finishes its buffer stream, so the
        // transcriber loops drain the queued audio and flush the in-progress
        // utterance through ASR. Then AWAIT the transcriber tasks instead of
        // cancelling them: FluidAudio and WhisperKit check
        // `Task.checkCancellation()` throughout inference, so the old
        // cancel-first teardown made the stop-time flush throw and silently
        // dropped the tail of every recording that was mid-speech at stop
        // (task-13 smoke test, 2026-07-09: "ASR error" at stop, truncated or
        // empty transcripts with the speech intact in the retained audio).
        // Stop whichever system source is active — stopping both is harmless and
        // simpler than branching. `systemSourceMode` is deliberately NOT reset
        // here: the stop-time telemetry accessors below (and ContentView's
        // snapshot) still need to know which leg's counters to read. The next
        // `start()` resets it.
        await systemCapture.stop()
        await systemDeviceCapture.stop()
        await micCapture.stop()
        await drainTranscriberTasks()
        micTask = nil
        // A startup-gate rebuild racing this stop could have swapped in a NEW
        // sysTask after drainTranscriberTasks snapshotted the old one — that
        // task was never drained, so cancel (not just drop) the reference.
        sysTask?.cancel()
        sysTask = nil
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
        endLiveActivity()
    }

    /// Wait for the transcriber tasks to finish their end-of-stream flush.
    /// Bounded: a wedged ASR call must not hang stop forever — past the
    /// deadline the tasks are cancelled, abandoning the pending segment (the
    /// retained recording still preserves that audio).
    private func drainTranscriberTasks(deadline: Duration = .seconds(15)) async {
        let tasks = [micTask, sysTask].compactMap { $0 }
        guard !tasks.isEmpty else { return }
        let watchdog = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            diagLog("[ENGINE-STOP] transcriber drain exceeded \(deadline) — cancelling")
            for task in tasks { task.cancel() }
        }
        for task in tasks { await task.value }
        watchdog.cancel()
    }

    // MARK: - Activity assertion + system-audio watchdog

    private func beginLiveActivity() {
        guard liveActivity == nil else { return }
        liveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Tome live transcription"
        )
        diagLog("[ENGINE-ACTIVITY] begin (display + system sleep disabled)")
    }

    private func endLiveActivity() {
        if let activity = liveActivity {
            ProcessInfo.processInfo.endActivity(activity)
            liveActivity = nil
            diagLog("[ENGINE-ACTIVITY] end")
        }
    }

    /// SCStream can pause silently (no `didStopWithError` callback) when the display
    /// sleeps, the captured app quits, or capture permission is revoked — and the
    /// mic tap can likewise stop delivering with no error when the device is pulled
    /// or the HAL wedges. Poll both legs' last-sample timestamps through
    /// `CaptureStallDetector`s. On a stall: set `lastError` AND post a notification
    /// (the Tome window is usually hidden behind the meeting app exactly when this
    /// matters). A stalled mic additionally gets one automatic restart attempt per
    /// stall episode.
    private func startCaptureWatchdog(systemLegActive: Bool) {
        sysWatchdogTask?.cancel()
        let sysCapture = systemCapture
        let sysDeviceCapture = systemDeviceCapture
        // The watchdog polls off the main actor, so it reads the active source
        // through the lock rather than the MainActor-isolated property.
        let sourceMode = _systemSourceMode
        let mic = micCapture
        sysWatchdogTask = Task { [weak self] in
            var sysDetector = CaptureStallDetector(threshold: 15)
            var micDetector = CaptureStallDetector(threshold: 15)
            var stalledTicksSinceRestart = 0
            var sysStalledTicksSinceRestart = 0
            var failedRecoveryAttempts = 0
            var lastTick = Date()
            let watchdogStart = Date()
            var postedSystemSilent = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                let now = Date()
                // System sleep detection: Task.sleep runs on a clock that keeps
                // counting across a lid-close, so after wake the sample gaps
                // include the entire sleep. That's not a capture stall — reset
                // both detectors and let a fresh window elapse before alarming
                // (a real post-wake stall alarms one threshold later).
                if now.timeIntervalSince(lastTick) > 15 {
                    diagLog("[WATCHDOG] tick gap \(Int(now.timeIntervalSince(lastTick)))s — system slept; resetting stall windows")
                    sysDetector = CaptureStallDetector(threshold: 15)
                    micDetector = CaptureStallDetector(threshold: 15)
                    lastTick = now
                    continue
                }
                lastTick = now

                // Which capture object owns the system leg right now. Re-read
                // every tick: a rebuild can move the leg between SCK and the
                // configured device mid-session.
                let deviceMode = sourceMode.withLock { $0 }.isDevice

                // Content-aware empty-leg check: SCStream delivers buffers
                // continuously even for pure digital silence (verified
                // 2026-07-24), so the stall detectors below can never see an
                // EMPTY system leg — only a stopped one. The same holds for an
                // unfed mixer device. One warning per session at +60s with zero
                // audible buffers; deliberately not the 8s startup-gate window,
                // where a quiet meeting join would false-alarm every time.
                if systemLegActive, !postedSystemSilent,
                   now.timeIntervalSince(watchdogStart) >= 60,
                   (deviceMode ? sysDeviceCapture.audibleBufferCount : sysCapture.audibleBufferCount) == 0 {
                    postedSystemSilent = true
                    diagLog("[WATCHDOG] no audible system audio 60s into the session — warning once")
                    let detail = Self.systemAudioSilentDetail(deviceMode: deviceMode, atStop: false)
                    Task { await NotificationPresenter.shared.postSystemAudioSilent(detail: detail) }
                }

                // The mic's tap-written timestamp is authoritative; the start
                // seed is only a baseline so a never-delivering device still
                // alarms. A seeded clock must never CLEAR a stall (see
                // CaptureStallDetector.evaluate(canResume:)).
                let micTapSample = mic.lastSampleTime
                // canResume mirrors the mic rule: `lastSampleTime` is SEEDED at
                // bufferStream start, and a system-leg rebuild re-seeds it — only
                // a real delivered buffer (firstSampleTime set) may clear the
                // stall latch, or every rebuild would phantom-resume the alarm.
                // In device mode the leg follows the MIC shape instead: MicCapture
                // writes `lastSampleTime` only from the tap, so the start seed is
                // `captureStartTime` (a device that never delivers still alarms one
                // threshold after start, and can never clear).
                let sysTapSample = deviceMode ? sysDeviceCapture.lastSampleTime : sysCapture.lastSampleTime
                let sysFirstSample = deviceMode ? sysDeviceCapture.firstSampleTime : sysCapture.firstSampleTime
                let sysEvent = systemLegActive
                    ? sysDetector.evaluate(
                        lastSample: deviceMode ? (sysTapSample ?? sysDeviceCapture.captureStartTime) : sysTapSample,
                        now: now,
                        canResume: deviceMode ? sysTapSample != nil : sysFirstSample != nil
                    )
                    : nil
                let micEvent = micDetector.evaluate(
                    lastSample: micTapSample ?? mic.captureStartTime,
                    now: now,
                    canResume: micTapSample != nil
                )

                // System-leg auto-rebuild, same discipline as the mic side: one
                // attempt when the stall first latches, then re-attempt every 3
                // stalled ticks. The latch (not fresh events) drives the cadence —
                // each rebuild re-seeds the sample clock, so fresh stall events
                // only fire ~15s apart while the latch counts every tick.
                var attemptSysRestart = false
                if let sysEvent {
                    switch sysEvent {
                    case .stalled:
                        attemptSysRestart = true
                        sysStalledTicksSinceRestart = 0
                    case .resumed:
                        sysStalledTicksSinceRestart = 0
                    }
                } else if sysDetector.isStalled {
                    sysStalledTicksSinceRestart += 1
                    if sysStalledTicksSinceRestart >= 3 {
                        sysStalledTicksSinceRestart = 0
                        attemptSysRestart = true
                        diagLog("[WATCHDOG] system audio still stalled — re-attempting rebuild")
                    }
                }

                var attemptMicRestart = false
                if let micEvent {
                    switch micEvent {
                    case .stalled:
                        attemptMicRestart = true
                        stalledTicksSinceRestart = 0
                    case .resumed:
                        stalledTicksSinceRestart = 0
                    }
                } else if micDetector.isStalled {
                    // Still latched with no fresh event: re-attempt periodically
                    // rather than once per episode — a restart that lands inside a
                    // mid-transition Bluetooth graph dies too, and the next attempt
                    // a few ticks later finds settled ground (observed 2026-07-06).
                    stalledTicksSinceRestart += 1
                    if stalledTicksSinceRestart >= 3 {
                        stalledTicksSinceRestart = 0
                        attemptMicRestart = true
                        diagLog("[WATCHDOG] mic still stalled — re-attempting restart")
                    }
                } else if micTapSample == nil && mic.captureStartTime == nil {
                    // Blind spot (observed 2026-07-06: "couldn't fail back" after
                    // AirPods disconnect): a restart that FAILED at setup leaves
                    // both timestamps nil — no engine ever started, so no stall
                    // ever latches, and the detector reads the leg as intentionally
                    // absent. A mic leg in a running session is never intentionally
                    // absent: treat all-nil as down and retry on the same cadence.
                    stalledTicksSinceRestart += 1
                    if stalledTicksSinceRestart >= 3 {
                        stalledTicksSinceRestart = 0
                        attemptMicRestart = true
                        diagLog("[WATCHDOG] mic is down (no capture running) — attempting restart")
                    }
                } else {
                    stalledTicksSinceRestart = 0
                }

                // Track recovery outcomes: any sign of life resets the counter.
                if micEvent == .resumed || (micTapSample.map { now.timeIntervalSince($0) < 10 } ?? false) {
                    failedRecoveryAttempts = 0
                }
                if attemptMicRestart { failedRecoveryAttempts += 1 }

                // Graceful surrender: a pinned device that keeps failing recovery
                // (macOS deliberately moves input to AirPods on connect; fighting
                // that bounces capture on/off indefinitely — field-observed
                // 2026-07-06). After 3 failed cycles, follow the system default for
                // THIS session; Settings keeps the user's pin for next time.
                let surrenderPin = attemptMicRestart && failedRecoveryAttempts >= 3

                guard sysEvent != nil || micEvent != nil || attemptMicRestart || attemptSysRestart else { continue }
                let restart = attemptMicRestart
                let sysRestart = attemptSysRestart
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    if let sysEvent { self.handleStallEvent(sysEvent, leg: "System audio") }
                    if let micEvent { self.handleStallEvent(micEvent, leg: "Microphone") }
                    if sysRestart {
                        diagLog("[WATCHDOG] attempting automatic system-audio rebuild")
                        // Async and generation-guarded; the stall banner from
                        // handleStallEvent stays up until real samples resume.
                        Task { await self.restartSystemAudioLeg() }
                    }
                    if surrenderPin && !self.userSelectedDeviceUID.isEmpty {
                        diagLog("[WATCHDOG] pinned mic failed \(failedRecoveryAttempts) recovery cycles — following System Default for this session")
                        let msg = "The selected microphone kept failing — following the system default for this session. Your Settings choice is unchanged."
                        self.lastError = msg
                        Task { await NotificationPresenter.shared.postCaptureStall(leg: "Microphone", detail: msg) }
                        self.userSelectedDeviceUID = ""
                        Task { await self.restartMic(inputDeviceUID: "", force: true) }
                    } else if restart {
                        diagLog("[WATCHDOG] attempting automatic mic restart")
                        Task { await self.restartMic(inputDeviceUID: self.userSelectedDeviceUID, force: true) }
                    }
                }
            }
        }
    }

    private func handleStallEvent(_ event: CaptureStallDetector.Event, leg: String) {
        switch event {
        case .stalled(let gap):
            let msg = "\(leg) capture stalled (\(gap)s) — audio is not being recorded"
            lastError = msg
            diagLog("[WATCHDOG] \(msg)")
            Task { await NotificationPresenter.shared.postCaptureStall(leg: leg, detail: msg) }
        case .resumed:
            diagLog("[WATCHDOG] \(leg) capture resumed")
            // Leg-specific clear: a mic resume must not wipe a still-active
            // system-audio stall banner (or vice versa).
            if lastError?.hasPrefix("\(leg) capture stalled") == true {
                lastError = nil
            }
            NotificationPresenter.shared.clearCaptureStall(leg: leg)
        }
    }

    /// Stateless diarization: reads a WAV at `bufferURL` and returns speaker segments.
    /// Intended for use by `PostProcessingJob` without reaching into engine state.
    nonisolated static func runDiarization(
        bufferURL: URL,
        clusterThreshold: Float,
        numberOfSpeakers: Int
    ) async -> DiarizationOutput? {
        guard FileManager.default.fileExists(atPath: bufferURL.path) else {
            diagLog("[DIARIZE] No buffered system audio file at \(bufferURL.path)")
            return nil
        }

        diagLog("[DIARIZE] Starting SpeakerKit diarization on \(bufferURL.lastPathComponent)")

        do {
            diagLog("[DIARIZE] Loading audio...")
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: bufferURL.path)

            // Need at least 2 seconds of 16kHz audio for meaningful diarization
            let minSamples = 32_000
            guard audioArray.count >= minSamples else {
                diagLog("[DIARIZE] Audio too short for diarization (\(audioArray.count) samples, need \(minSamples)), skipping")
                return nil
            }

            diagLog("[DIARIZE] Preparing SpeakerKit models...")
            let speakerKit = try await SpeakerKit(PyannoteConfig())

            let options = PyannoteDiarizationOptions(
                numberOfSpeakers: numberOfSpeakers > 0 ? numberOfSpeakers : nil,
                clusterDistanceThreshold: clusterThreshold
            )

            diagLog("[DIARIZE] Processing audio (clusterThreshold=\(clusterThreshold), numberOfSpeakers=\(numberOfSpeakers))...")
            let result = try await speakerKit.diarize(audioArray: audioArray, options: options)

            let segments = result.segments.map { seg -> DiarizedSegment in
                let id: String
                switch seg.speaker {
                case .speakerId(let speakerId):
                    id = "SPEAKER_\(speakerId)"
                case .multiple(let ids):
                    id = "SPEAKER_\(ids.first ?? 0)"
                case .noMatch:
                    id = "SPEAKER_UNKNOWN"
                @unknown default:
                    // SpeakerInfo is non-frozen in argmax-oss-swift 1.0+; map any
                    // future case to an unmatched speaker.
                    id = "SPEAKER_UNKNOWN"
                }
                return DiarizedSegment(speakerId: id, startTime: seg.startTime, endTime: seg.endTime)
            }

            // Map per-cluster centroids (keyed by Int clusterId) onto the same
            // "SPEAKER_n" ids used for the segments, so callers can join them.
            let centroids: [String: [Float]] = result.speakerCentroidEmbeddings.reduce(into: [:]) { acc, pair in
                acc["SPEAKER_\(pair.key)"] = pair.value
            }

            diagLog("[DIARIZE] Found \(segments.count) segments, \(Set(segments.map(\.speakerId)).count) speakers, \(centroids.count) centroids")
            return DiarizationOutput(segments: segments, centroids: centroids)
        } catch {
            diagLog("[DIARIZE] Failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stateless re-transcription: runs `SegmentReTranscriber` against `bufferURL`,
    /// routing through the shared `ASRCoordinator` for safe interleaving with live streaming.
    /// `nonisolated` so heavy file I/O from background jobs doesn't block the main actor.
    nonisolated static func reTranscribe(
        asrCoordinator: ASRCoordinator,
        bufferURL: URL,
        segments: [DiarizedSegment],
        speakerNumberBase: Int = 2,
        mergeGapSeconds: Double = 1.5
    ) async -> [ReTranscribedSegment]? {
        guard FileManager.default.fileExists(atPath: bufferURL.path) else {
            diagLog("[RETRANSCRIBE] FAILED: Buffer file missing at \(bufferURL.path)")
            return nil
        }

        diagLog("[RETRANSCRIBE] Starting re-transcription of \(segments.count) segments from \(bufferURL.lastPathComponent)")

        let transcriber = SegmentReTranscriber(
            asrCoordinator: asrCoordinator,
            fileURL: bufferURL,
            segments: segments,
            speakerNumberBase: speakerNumberBase,
            mergeGapSeconds: mergeGapSeconds
        )
        let results = await transcriber.run()

        diagLog("[RETRANSCRIBE] Result: \(results?.count ?? -1) segments produced")
        return results
    }

    /// Clean up the system audio buffer file for the current session and forget its URL.
    func cleanupBuffer() {
        if let url = currentBufferURL {
            SystemAudioCapture.cleanupBufferFile(url)
        }
        currentBufferURL = nil
    }

    /// The WAV buffer URL for the currently-live (or most recently live) capture.
    /// Callers can snapshot this at stop time before starting a new session.
    var activeBufferURL: URL? { currentBufferURL }

    /// Mic-track retention WAV URL for the current capture. Snapshot at stop time.
    var activeMicBufferURL: URL? { currentMicBufferURL }

    /// Wall-clock of the first mic / system sample for the current capture. Used by
    /// the post-session mixer to align each track to the session start.
    var micFirstSampleTime: Date? { micCapture.firstSampleTime }

    // The three system-leg telemetry accessors below route to whichever source
    // the session actually bound, so every downstream consumer — the startup
    // gate, the rebuild grace check, the watchdog, SessionHandle, the
    // end-of-session note — works identically in both modes.
    var systemFirstSampleTime: Date? {
        systemSourceMode.isDevice ? systemDeviceCapture.firstSampleTime : systemCapture.firstSampleTime
    }

    /// Count of write failures on the system-audio WAV during the active capture.
    /// Snapshot at stop time, before `stop()` resets the capture's internal counter.
    var systemAudioWriteErrorCount: Int {
        systemSourceMode.isDevice ? systemDeviceCapture.writeErrorCount : systemCapture.writeErrorCount
    }

    /// Buffers with audible content delivered on the system leg this session.
    /// ContentView snapshots this at stop (before `stop()` frees the capture for
    /// reuse) to append the "no system audio was captured" note for call
    /// captures that stayed at zero.
    var systemAudioAudibleBufferCount: Int {
        systemSourceMode.isDevice ? systemDeviceCapture.audibleBufferCount : systemCapture.audibleBufferCount
    }

    /// True when the system leg is (or, at stop time, was) captured from a
    /// user-selected input device rather than ScreenCaptureKit. Read by
    /// ContentView so the "no system audio" note points at the mixer's mix
    /// routing instead of the (inert in this mode) exclusion settings.
    var systemAudioSourceIsDevice: Bool { systemSourceMode.isDevice }
}
