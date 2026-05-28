@preconcurrency import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os
import SpeakerKit
import WhisperKit

// Writes to /tmp/tome.log
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/tome.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
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
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

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
        recordingContext: SessionRecordingContext? = nil
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
            await asrCoordinator.resetDecoderState()

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
        let micStream = micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)

        // 3. Start system audio capture
        diagLog("[ENGINE-4] starting system audio capture...")
        let sysStreams: SystemAudioCapture.CaptureStreams?
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
            startSystemAudioWatchdog()
        }

        assetStatus = "Transcribing (Parakeet-TDT v3)"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) {
        guard isRunning, let vadManager else { return }

        // Only update user selection when explicitly changed (not from OS listener)
        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        // Tear down old mic
        micTask?.cancel()
        micTask = nil
        micCapture.stop()

        currentMicDeviceID = targetMicID

        // Start new mic stream. The retention writer reopens (overwriting) at the same
        // path — a mid-session mic device change truncates the kept recording to the
        // post-swap segment, so retained recordings assume a stable mic for the session.
        let micStream = micCapture.bufferStream(deviceID: targetMicID, recordOutputURL: currentMicBufferURL)
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
        micKeepAliveTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
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
    /// sleeps, the captured app quits, or capture permission is revoked. Poll the
    /// last-sample timestamp; if the gap exceeds the threshold while running, surface
    /// a visible warning so a future regression here is loud instead of silent.
    private func startSystemAudioWatchdog() {
        sysWatchdogTask?.cancel()
        let capture = systemCapture
        sysWatchdogTask = Task { [weak self] in
            let stallThreshold: TimeInterval = 15
            var warned = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                let last = capture.lastSampleTime
                await MainActor.run {
                    guard let self else { return }
                    guard self.isRunning else { return }
                    guard let last else { return }
                    let gap = Date().timeIntervalSince(last)
                    if gap > stallThreshold {
                        if !warned {
                            let msg = "System audio capture stalled (\(Int(gap))s) — restart the session"
                            self.lastError = msg
                            diagLog("[WATCHDOG] system audio gap=\(Int(gap))s — \(msg)")
                            warned = true
                        }
                    } else if warned {
                        // Samples resumed flowing — clear the warning if we set it.
                        if self.lastError?.hasPrefix("System audio capture stalled") == true {
                            self.lastError = nil
                        }
                        warned = false
                        diagLog("[WATCHDOG] system audio resumed")
                    }
                }
            }
        }
    }

    /// Run offline diarization on the buffered system audio using SpeakerKit (pyannote v4).
    /// Uses the buffer URL captured when this session started. Returns speaker segments,
    /// or nil if no audio was buffered / it was too short.
    func runPostSessionDiarization(clusterThreshold: Float, numberOfSpeakers: Int) async -> [DiarizedSegment]? {
        guard let bufferURL = currentBufferURL else {
            diagLog("[DIARIZE] No buffer URL tracked for this session")
            return nil
        }
        return await Self.runDiarization(
            bufferURL: bufferURL,
            clusterThreshold: clusterThreshold,
            numberOfSpeakers: numberOfSpeakers
        )
    }

    /// Stateless diarization: reads a WAV at `bufferURL` and returns speaker segments.
    /// Intended for use by `PostProcessingJob` without reaching into engine state.
    nonisolated static func runDiarization(
        bufferURL: URL,
        clusterThreshold: Float,
        numberOfSpeakers: Int
    ) async -> [DiarizedSegment]? {
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
                }
                return DiarizedSegment(speakerId: id, startTime: seg.startTime, endTime: seg.endTime)
            }

            diagLog("[DIARIZE] Found \(segments.count) segments, \(Set(segments.map(\.speakerId)).count) speakers")
            return segments
        } catch {
            diagLog("[DIARIZE] Failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-transcribe the session's buffered WAV using diarization segment boundaries.
    func reTranscribeWithDiarization(
        segments: [DiarizedSegment]
    ) async -> [ReTranscribedSegment]? {
        guard let bufferURL = currentBufferURL else {
            diagLog("[RETRANSCRIBE] FAILED: No buffer URL tracked")
            return nil
        }
        return await Self.reTranscribe(asrCoordinator: asrCoordinator, bufferURL: bufferURL, segments: segments)
    }

    /// Stateless re-transcription: runs `SegmentReTranscriber` against `bufferURL`,
    /// routing through the shared `ASRCoordinator` for safe interleaving with live streaming.
    /// `nonisolated` so heavy file I/O from background jobs doesn't block the main actor.
    nonisolated static func reTranscribe(
        asrCoordinator: ASRCoordinator,
        bufferURL: URL,
        segments: [DiarizedSegment]
    ) async -> [ReTranscribedSegment]? {
        guard FileManager.default.fileExists(atPath: bufferURL.path) else {
            diagLog("[RETRANSCRIBE] FAILED: Buffer file missing at \(bufferURL.path)")
            return nil
        }

        diagLog("[RETRANSCRIBE] Starting re-transcription of \(segments.count) segments from \(bufferURL.lastPathComponent)")

        let transcriber = SegmentReTranscriber(
            asrCoordinator: asrCoordinator,
            fileURL: bufferURL,
            segments: segments
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
