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

    init(transcriptStore: TranscriptStore, asrCoordinator: ASRCoordinator) {
        self.transcriptStore = transcriptStore
        self.asrCoordinator = asrCoordinator
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        appBundleID: String? = nil,
        recordingContext: SessionRecordingContext? = nil,
        captureSystemAudio: Bool = true
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning)")
        guard !isRunning else { return }
        lastError = nil

        guard await ensureMicrophonePermission() else { return }

        isRunning = true
        beginLiveActivity()

        // 1. Load FluidAudio models
        assetStatus = "Loading ASR model (~600MB first run)..."
        diagLog("[ENGINE-1] loading FluidAudio ASR models...")
        do {
            try await asrCoordinator.initialize()
            assetStatus = "Initializing ASR..."

            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] FluidAudio models loaded")
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

        // 2. Start mic capture
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
            assetStatus = "Ready"
            isRunning = false
            endLiveActivity()
            return
        }

        // 3. Start system audio capture. Skipped for mic-only sessions (voice memos /
        //    in-person meetings) — there the mic is the sole source and diarization runs
        //    on the mic track, so capturing system audio would only add a stray "Them"
        //    stream and a needless ScreenCaptureKit permission prompt.
        let sysStreams: SystemAudioCapture.CaptureStreams?
        if captureSystemAudio {
            diagLog("[ENGINE-4] starting system audio capture...")
            do {
                sysStreams = try await systemCapture.bufferStream(
                    appBundleID: appBundleID,
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

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrCoordinator: asrCoordinator,
            vadManager: vadManager,
            speaker: .you,
            audioSource: .microphone,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, startTime in
                Task { @MainActor in
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
            let sysTranscriber = StreamingTranscriber(
                asrCoordinator: asrCoordinator,
                vadManager: vadManager,
                speaker: .them,
                audioSource: .system,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text, startTime in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them, timestamp: startTime))
                    }
                }
            )
            let reportSysError: @Sendable (String) -> Void = { [weak self] msg in
                Task { @MainActor in self?.lastError = msg }
            }
            sysTask = Task.detached {
                let hadFatalError = await sysTranscriber.run(stream: sysStream)
                if hadFatalError {
                    reportSysError("System audio transcription failed — restart session")
                }
            }
        }

        // Watch BOTH capture legs, not just system audio — a mic that stops
        // delivering (device pulled, HAL wedge) is silent loss of the user's own
        // side, and flowing system audio masks it from the level-based silence
        // detection entirely.
        startCaptureWatchdog(systemLegActive: sysStreams != nil)

        assetStatus = "Transcribing (Parakeet-TDT v3)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    /// `force` skips the same-device short-circuit — used by the capture watchdog to
    /// re-establish a mic whose tap stopped delivering on the SAME device.
    func restartMic(inputDeviceID: AudioDeviceID, force: Bool = false) {
        guard isRunning, let vadManager else { return }

        // Only update user selection when explicitly changed (not from OS listener)
        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard force || targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // Tear down old mic
        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = targetMicID

        // Start new mic stream. The retention writer reopens in `.append` mode at
        // the same path, so the pre-swap audio is preserved (see MicCapture).
        let micStream = micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)

        // Setup failures are synchronous (see start()) — a failed restart means the
        // user's side is NOT being recorded. Surface loudly; the session continues
        // (system audio may still be flowing) and the watchdog keeps monitoring.
        if let micError = micCapture.captureError {
            let msg = "Mic restart failed: \(micError)"
            lastError = msg
            diagLog("[ENGINE-MIC-SWAP-FAIL] \(msg)")
            Task { await NotificationPresenter.shared.postCaptureStall(leg: "Microphone", detail: msg) }
        }
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            asrCoordinator: asrCoordinator,
            vadManager: vadManager,
            speaker: .you,
            audioSource: .microphone,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text, startTime in
                Task { @MainActor in
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
        sysWatchdogTask?.cancel()
        sysWatchdogTask = nil
        micTask?.cancel()
        sysTask?.cancel()
        micTask = nil
        sysTask = nil
        await systemCapture.stop()
        micCapture.stop()
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
        endLiveActivity()
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
            var micRestartAttempted = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                let now = Date()
                let sysEvent = systemLegActive
                    ? sysDetector.evaluate(lastSample: sysCapture.lastSampleTime, now: now)
                    : nil
                let micEvent = micDetector.evaluate(lastSample: mic.lastSampleTime, now: now)

                var attemptMicRestart = false
                if let micEvent {
                    switch micEvent {
                    case .stalled:
                        if !micRestartAttempted {
                            micRestartAttempted = true
                            attemptMicRestart = true
                        }
                    case .resumed:
                        micRestartAttempted = false
                    }
                }

                guard sysEvent != nil || micEvent != nil else { continue }
                let restart = attemptMicRestart
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    if let sysEvent { self.handleStallEvent(sysEvent, leg: "System audio") }
                    if let micEvent { self.handleStallEvent(micEvent, leg: "Microphone") }
                    if restart {
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
            if lastError?.contains("capture stalled") == true {
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
