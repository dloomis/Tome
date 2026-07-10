@preconcurrency import AVFoundation
import CoreAudio
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

/// Dual-stream mic + system audio transcription.
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    var assetStatus: String = "Ready"
    var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Combined audio level from mic and system for the UI meter.
    var audioLevel: Float { max(micCapture.audioLevel, systemCapture.audioLevel) }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

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

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

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
        inputDeviceID: AudioDeviceID = 0,
        recordingContext: SessionRecordingContext? = nil,
        captureSystemAudio: Bool = true
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
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
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
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

        let micStream = micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)

        // The stream-setup closure runs synchronously inside `bufferStream`, so any
        // setup failure (no HAL input, device-set failure, tap format exception,
        // engine-start throw) is already in `captureError` here. A session with no
        // working mic must not pretend to record — fail the start and let
        // ContentView's rollback unwind the bookkeeping. (`captureError` previously
        // had no readers at all: a wedged input device produced a session that
        // looked live and recorded nothing.)
        if let micError = micCapture.captureError {
            diagLog("[ENGINE-3-FAIL] mic capture failed at start: \(micError)")
            lastError = micError
            micCapture.stop()
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

        // 3. Start system audio capture. Skipped for mic-only sessions (voice memos /
        //    in-person meetings) — there the mic is the sole source and diarization runs
        //    on the mic track, so capturing system audio would only add a stray "Them"
        //    stream and a needless ScreenCaptureKit permission prompt.
        let sysStreams: SystemAudioCapture.CaptureStreams?
        if captureSystemAudio {
            diagLog("[ENGINE-4] starting system audio capture...")
            do {
                sysStreams = try await systemCapture.bufferStream(
                    recordingContext: recordingContext
                )
                currentBufferURL = sysStreams?.bufferURL
                diagLog("[ENGINE-5] system audio capture started OK")
            } catch {
                let msg = "Failed to start system audio: \(error.localizedDescription)"
                diagLog("[ENGINE-5-FAIL] \(msg)")
                lastError = msg
                sysStreams = nil
            }
        } else {
            diagLog("[ENGINE-4] system audio capture skipped (mic-only session)")
            sysStreams = nil
            currentBufferURL = nil
        }

        // Same stop-during-await race as after model load: the system-audio
        // bring-up suspended above. If stop ran meanwhile, unwind the capture we
        // just started instead of leaving a headless recording.
        guard isRunning else {
            diagLog("[ENGINE-4-ABORT] stopped during capture bring-up — unwinding")
            micCapture.stop()
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
        if let sysStream = sysStreams?.systemAudio {
            spinUpSystemTranscription(stream: sysStream, vadManager: vadManager)
        }

        // 5b. System-audio startup-delivery gate: SCStream's per-stream cold start
        //     can race the same way the mic's A2DP→HFP flip does — startCapture()
        //     succeeds but the tap delivers nothing, with no didStopWithError. Force
        //     ONE rebuild of the system leg if no sample lands within the window,
        //     collapsing the wait before the 15s stall watchdog would alarm. Only
        //     armed when we actually brought the leg up.
        if sysStreams != nil {
            armSystemStartupDeliveryGate()
        }

        // Watch BOTH capture legs, not just system audio — a mic that stops
        // delivering (device pulled, HAL wedge) is silent loss of the user's own
        // side, and flowing system audio masks it from the level-based silence
        // detection entirely.
        startCaptureWatchdog(systemLegActive: sysStreams != nil)

        let modelName = await asrCoordinator.activeModel?.displayName ?? "ASR"
        assetStatus = "Transcribing (\(modelName))"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
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

    /// Arm the one-shot system-audio startup-delivery gate. Mirrors
    /// `armStartupDeliveryGate` (the mic side) but for the SCStream leg: if no
    /// sample arrives within the window, rebuild the leg ONCE. The window is longer
    /// than the mic's 3s because ScreenCaptureKit's first-sample latency is higher
    /// (shareable-content query + stream negotiation), and still well inside the
    /// 15s stall watchdog that owns the persistent-failure alarm.
    private func armSystemStartupDeliveryGate() {
        sysStartupGateTask?.cancel()
        sysStartupGateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.handleSystemStartupGate()
        }
    }

    /// Fire-time decision + action for the system-audio startup gate. Rebuild only
    /// when the engine is still running, the leg has NEVER delivered a sample this
    /// session (`firstSampleTime == nil` — distinct from delivered-then-paused,
    /// which is the watchdog's job), and the gate hasn't already fired.
    @MainActor
    private func handleSystemStartupGate() async {
        guard isRunning, !sysStartupGateFired else { return }
        guard systemCapture.firstSampleTime == nil else { return }  // delivered — no-op
        sysStartupGateFired = true
        diagLog("[SYS-STARTGATE] no system-audio sample within 8s — rebuilding the system leg once")
        await restartSystemAudioLeg()
    }

    /// Tear down and re-establish the system-audio leg on the current session.
    /// Used only by the startup gate. Reuses the retained recording context so the
    /// rebuilt WAV keeps the same session identity/path. If the rebuild itself
    /// fails to come up, surface it — a persistent zero-delivery is a
    /// permission/routing problem a further retry won't fix, and the 15s stall
    /// watchdog remains the backstop for a rebuilt-but-still-silent leg.
    @MainActor
    private func restartSystemAudioLeg() async {
        guard isRunning, let vadManager else { return }
        sysTask?.cancel()
        sysTask = nil
        await systemCapture.stop()
        // stop()/bufferStream both suspend; a session stop could have raced in.
        guard isRunning else { return }
        do {
            let streams = try await systemCapture.bufferStream(recordingContext: activeRecordingContext)
            guard isRunning else { await systemCapture.stop(); return }
            currentBufferURL = streams.bufferURL
            spinUpSystemTranscription(stream: streams.systemAudio, vadManager: vadManager)
            diagLog("[SYS-STARTGATE] system leg rebuilt")
        } catch {
            let msg = "System audio isn't being captured — recording mic only."
            diagLog("[SYS-STARTGATE] rebuild failed: \(error.localizedDescription)")
            lastError = msg
            Task { await NotificationPresenter.shared.postCaptureStall(leg: "System audio", detail: msg) }
        }
    }

    /// Pure decision for the startup-delivery gate (below). Extracted so the
    /// never-delivered-vs-delivered distinction and the strict one-shot rule can
    /// be unit-tested without audio hardware. Force a single mic restart only
    /// when the engine is still running, the tap has NEVER delivered a sample
    /// this session (`firstSampleAt == nil` — distinct from delivered-then-quiet,
    /// which is the watchdog's job), the gate hasn't already fired, and no
    /// debounced config/HAL rebuild is already in flight (that rebuild re-opens
    /// the mic on its own — don't stack a second restart on top).
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
                self.restartMic(inputDeviceID: self.userSelectedDeviceID, force: true, silent: true)
            }
        }
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
            self.restartMic(inputDeviceID: self.userSelectedDeviceID, force: true)
        }
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    /// `force` skips the same-device short-circuit — used by the capture watchdog to
    /// re-establish a mic whose tap stopped delivering on the SAME device.
    /// `updateSelection: false` marks an EMERGENCY rebind (fallback to default after
    /// a failed device bind): capture moves, but the user's intent is preserved so
    /// watchdog retries keep aiming at the chosen device until it's bindable again.
    /// `silent: true` marks a startup-gate fast retry: on bind failure it does NOT
    /// post the user-facing stall notification or set `lastError` for this attempt
    /// — the true never-delivers wedge is still owned by the stall watchdog. Any
    /// recursive fallback restart inside a silent attempt stays silent.
    func restartMic(inputDeviceID: AudioDeviceID, force: Bool = false, updateSelection: Bool = true, silent: Bool = false) {
        guard isRunning, let vadManager else { return }

        // Only update user selection when explicitly changed (not from OS listener,
        // not from an emergency fallback)
        if updateSelection, inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard force || targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // A user/watchdog-initiated restart supersedes any pending debounced rebuild.
        micRebuildTask?.cancel()
        micRebuildTask = nil

        // Tear down old mic
        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = targetMicID

        // Start new mic stream. The retention writer reopens in `.append` mode at
        // the same path, so the pre-swap audio is preserved (see MicCapture).
        let micStream = micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)

        // Setup failures are synchronous (see start()) — a failed restart means the
        // user's side is NOT being recorded. Surface loudly, and try ONE fallback
        // to the system default before giving up: a specific device refusing to
        // bind (HAL 'nope' during a Bluetooth transition, a stale id) shouldn't
        // leave the mic dead when another input would work. The watchdog keeps
        // monitoring either way.
        if let micError = micCapture.captureError {
            let msg = "Mic restart failed: \(micError)"
            if silent {
                // Startup-gate fast retry: no user-facing alarm for this attempt.
                // If the mic truly never binds, the stall watchdog owns the rescue.
                diagLog("[MIC-STARTGATE] silent restart failed to bind — leaving rescue to the stall watchdog")
            } else {
                lastError = msg
                diagLog("[ENGINE-MIC-SWAP-FAIL] \(msg)")
                Task { await NotificationPresenter.shared.postCaptureStall(leg: "Microphone", detail: msg) }
            }
            if targetMicID != 0,
               let fallback = MicCapture.defaultInputDeviceID(), fallback != targetMicID {
                diagLog("[ENGINE-MIC-SWAP] falling back to system default input (\(fallback)) — user selection preserved")
                restartMic(inputDeviceID: 0, force: true, updateSelection: false, silent: silent)
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
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                // User has "System Default" selected — follow the OS default
                self.restartMic(inputDeviceID: 0)
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
        lastError = nil
        removeDefaultDeviceListener()
        startupGateTask?.cancel()
        startupGateTask = nil
        sysStartupGateTask?.cancel()
        sysStartupGateTask = nil
        activeRecordingContext = nil
        micRebuildTask?.cancel()
        micRebuildTask = nil
        micCapture.onConfigurationChange = nil
        recentMicRebuilds = []
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
        await systemCapture.stop()
        micCapture.stop()
        await drainTranscriberTasks()
        micTask = nil
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
        let mic = micCapture
        sysWatchdogTask = Task { [weak self] in
            var sysDetector = CaptureStallDetector(threshold: 15)
            var micDetector = CaptureStallDetector(threshold: 15)
            var stalledTicksSinceRestart = 0
            var failedRecoveryAttempts = 0
            var lastTick = Date()
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

                // The mic's tap-written timestamp is authoritative; the start
                // seed is only a baseline so a never-delivering device still
                // alarms. A seeded clock must never CLEAR a stall (see
                // CaptureStallDetector.evaluate(canResume:)).
                let micTapSample = mic.lastSampleTime
                let sysEvent = systemLegActive
                    ? sysDetector.evaluate(lastSample: sysCapture.lastSampleTime, now: now)
                    : nil
                let micEvent = micDetector.evaluate(
                    lastSample: micTapSample ?? mic.captureStartTime,
                    now: now,
                    canResume: micTapSample != nil
                )

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

                guard sysEvent != nil || micEvent != nil || attemptMicRestart else { continue }
                let restart = attemptMicRestart
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    if let sysEvent { self.handleStallEvent(sysEvent, leg: "System audio") }
                    if let micEvent { self.handleStallEvent(micEvent, leg: "Microphone") }
                    if surrenderPin && self.userSelectedDeviceID != 0 {
                        diagLog("[WATCHDOG] pinned mic failed \(failedRecoveryAttempts) recovery cycles — following System Default for this session")
                        let msg = "The selected microphone kept failing — following the system default for this session. Your Settings choice is unchanged."
                        self.lastError = msg
                        Task { await NotificationPresenter.shared.postCaptureStall(leg: "Microphone", detail: msg) }
                        self.userSelectedDeviceID = 0
                        self.restartMic(inputDeviceID: 0, force: true)
                    } else if restart {
                        diagLog("[WATCHDOG] attempting automatic mic restart")
                        self.restartMic(inputDeviceID: self.userSelectedDeviceID, force: true)
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
        speakerNumberBase: Int = 2
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
            speakerNumberBase: speakerNumberBase
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
    var systemFirstSampleTime: Date? { systemCapture.firstSampleTime }

    /// Count of write failures on the system-audio WAV during the active capture.
    /// Snapshot at stop time, before `stop()` resets the capture's internal counter.
    var systemAudioWriteErrorCount: Int { systemCapture.writeErrorCount }
}
