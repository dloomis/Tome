import SwiftUI
import AppKit
import Combine

private let conferencingBundleIDs: [String: String] = [
    "com.microsoft.teams2": "Teams",
    "com.microsoft.teams": "Teams",
    "us.zoom.xos": "Zoom",
    "com.apple.FaceTime": "FaceTime",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.cisco.webexmeetingsapp": "Webex",
    "Cisco-Systems.Spark": "Webex",
    "com.google.Chrome": "Chrome",
    "company.thebrowser.Browser": "Arc",
    "com.apple.Safari": "Safari",
    "com.microsoft.edgemac": "Edge",
]

struct ContentView: View {
    @Bindable var settings: AppSettings
    let apiServer: APIServer
    let services: AppServices
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var audioLevel: Float = 0
    @State private var activeSessionType: SessionType?
    @State private var detectedAppName: String?
    @State private var silenceSeconds: Int = 0
    @State private var savedFileURL: URL?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var sessionElapsed: Int = 0
    /// Identity of the session currently being captured, carried through to the
    /// `PostProcessingJob` at stop time so the job can be tracked by session id.
    @State private var currentSessionId: String?
    @State private var currentSourceApp: String?

    /// Single-consumer channel that serializes utterance writes to the markdown
    /// transcript and the JSONL crash-recovery file. Prevents the two stores from
    /// drifting out of order when `handleNewUtterance` fires faster than the
    /// individual Task closures can run.
    @State private var utteranceContinuation: AsyncStream<UtteranceWrite>.Continuation?
    @State private var utteranceWriterTask: Task<Void, Never>?

    private struct UtteranceWrite: Sendable {
        let speaker: Speaker
        let text: String
        let timestamp: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            // Glass top bar
            topBar

            // Main content area
            if !isRunning && transcriptStore.utterances.isEmpty
                && transcriptStore.volatileYouText.isEmpty
                && transcriptStore.volatileThemText.isEmpty {
                emptyState
            } else {
                TranscriptView(
                    utterances: transcriptStore.utterances,
                    volatileYouText: transcriptStore.volatileYouText,
                    volatileThemText: transcriptStore.volatileThemText
                )
            }

            // Save banner
            if let url = savedFileURL, activeSessionType == nil {
                saveBanner(url: url)
            }

            // Waveform ribbon
            WaveformView(isRecording: isRunning, audioLevel: audioLevel)

            // Glass control bar
            ControlBar(
                isRecording: isRunning,
                activeSessionType: activeSessionType,
                audioLevel: audioLevel,
                detectedApp: detectedAppName,
                silenceSeconds: silenceSeconds,
                silenceAutoStopSeconds: settings.silenceAutoStopSeconds,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                onStartCallCapture: { startSession(type: .callCapture) },
                onStartVoiceMemo: { startSession(type: .voiceMemo) },
                onStop: stopSession
            )
        }
        .frame(minWidth: 280, maxWidth: 360, minHeight: 400)
        .background(Color.bg0)
        .preferredColorScheme(.dark)
        .overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            }
        }
        .onChange(of: showOnboarding) {
            if !showOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: settings.transcriptionLanguage) {
            // Push setting changes to the ASR actor so subsequent transcribe calls
            // use the new language hint. No UI for this setting yet — the hook is
            // here so the picker that lands next release works end-to-end.
            let language = settings.transcriptionLanguage
            Task { await services.asrCoordinator.setLanguage(language) }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if transcriptionEngine == nil {
                transcriptionEngine = TranscriptionEngine(
                    transcriptStore: transcriptStore,
                    asrCoordinator: services.asrCoordinator
                )
            }
            guard let engine = transcriptionEngine else { return }
            await services.asrCoordinator.setLanguage(settings.transcriptionLanguage)

            // Boot the single-consumer utterance writer so markdown + JSONL stay in lockstep.
            if utteranceWriterTask == nil {
                let (stream, cont) = AsyncStream.makeStream(of: UtteranceWrite.self)
                utteranceContinuation = cont
                let logger = services.transcriptLogger
                let store = services.sessionStore
                utteranceWriterTask = Task {
                    defer { diagLog("[CHANNEL] utterance writer exited") }
                    for await u in stream {
                        let speakerName = u.speaker == .you ? "You" : "Them"
                        await logger.append(speaker: speakerName, text: u.text, timestamp: u.timestamp)
                        await store.appendRecord(SessionRecord(speaker: u.speaker, text: u.text, timestamp: u.timestamp))
                    }
                }
            }

            apiServer.register(
                transcriptStore: transcriptStore,
                transcriptionEngine: engine,
                sessionStore: services.sessionStore,
                onStart: { type, sessionId, context, filename in startSession(type: type, sessionId: sessionId, meetingContext: context, suggestedFilename: filename) },
                onStop: { stopSession() }
            )
            apiServer.start()
        }
        // Audio level polling
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let engine = transcriptionEngine else {
                    if audioLevel != 0 { audioLevel = 0 }
                    continue
                }
                if engine.isRunning {
                    audioLevel = engine.audioLevel
                    if audioLevel > 0.01 {
                        silenceSeconds = 0
                    }
                } else if audioLevel != 0 {
                    audioLevel = 0
                }
            }
        }
        // Silence auto-stop + elapsed timer
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard isRunning else {
                    silenceSeconds = 0
                    continue
                }
                sessionElapsed += 1
                apiServer.sessionElapsed = sessionElapsed
                if audioLevel < 0.01 {
                    silenceSeconds += 1
                    let limit = settings.silenceAutoStopSeconds
                    if limit > 0 && silenceSeconds >= limit {
                        stopSession()
                    }
                }
            }
        }
        // Transcript buffer flush
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await services.transcriptLogger.flushIfNeeded()
                if let err = await services.transcriptLogger.lastError {
                    transcriptionEngine?.lastError = err
                }
            }
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count as Int) {
            handleNewUtterance()
        }
        .onChange(of: services.postProcessingQueue.lastCompletion) { _, new in
            guard let new else { return }
            handleJobCompleted(jobId: new.jobId, savedURL: new.savedURL, sessionType: new.sessionType)
        }
        .focusedSceneValue(\.saveTranscript, saveTranscriptAction)
    }

    private var saveTranscriptAction: (() -> Void)? {
        guard !transcriptStore.utterances.isEmpty else { return nil }
        return { saveTranscriptToFile() }
    }

    private func saveTranscriptToFile() {
        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Transcript.md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var md = "# Transcript\n\n"
        for u in transcriptStore.utterances {
            let speaker = u.speaker == .you ? "You" : "Them"
            md += "**\(speaker)** (\(timeFmt.string(from: u.timestamp)))\n"
            md += "\(u.text)\n\n"
        }

        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("TOME")
                .font(.system(size: 14, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color.fg1)

            // Active ASR language code. Driven by `AppSettings.transcriptionLanguage`
            // so the future Settings picker auto-updates this label.
            Text(settings.transcriptionLanguage.rawValue.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .foregroundStyle(Color.fg2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.fg2.opacity(0.35), lineWidth: 0.5)
                )
                .padding(.leading, 10)

            Spacer()

            HStack(spacing: 10) {
                Text(topBarStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isRunning ? Color.fg1 : Color.fg2)

                if isRunning {
                    PulsingDot(size: 6)
                } else {
                    Circle()
                        .fill(Color.fg2)
                        .frame(width: 6, height: 6)
                        .opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.bg1.opacity(0.45))
        .overlay(Divider(), alignment: .bottom)
    }

    private var topBarStatus: String {
        if isRunning {
            return formatTime(sessionElapsed)
        } else if savedFileURL != nil {
            return "\(formatTime(sessionElapsed)) · Done"
        } else if services.postProcessingQueue.isAnyJobRunning {
            return "Finalizing…"
        } else {
            return "Ready"
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 28))
                .foregroundStyle(Color.fg3)
            Text("No active session")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.fg2)
            Text("Start a call capture or voice memo\nto begin transcribing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.fg3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save Banner

    private func saveBanner(url: URL) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accent1.opacity(0.15))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accent1)
                )
            Text("Saved to \(url.lastPathComponent)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.fg1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                savedFileURL = nil
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accent1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bg1.opacity(0.7))
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Helpers

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    private func formatTime(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    // MARK: - Actions

    private func startSession(type: SessionType, sessionId: String? = nil, meetingContext: MeetingContext? = nil, suggestedFilename: String? = nil) {
        transcriptStore.clear()
        silenceSeconds = 0
        sessionElapsed = 0
        savedFileURL = nil
        bannerDismissTask?.cancel()

        let sid = sessionId ?? SessionStore.generateSessionId()

        // Determine output folder and app bundle ID based on session type
        let outputPath: String
        let sourceApp: String
        var appBundleID: String?
        var resolvedAppName: String?

        switch type {
        case .callCapture:
            outputPath = settings.vaultMeetingsPath
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               let bundleID = frontApp.bundleIdentifier,
               let appName = conferencingBundleIDs[bundleID] {
                sourceApp = appName
                appBundleID = bundleID
                resolvedAppName = appName
            } else {
                sourceApp = "Call"
            }
        case .voiceMemo:
            outputPath = settings.vaultVoicePath
            sourceApp = "Voice Memo"
        }

        Task {
            transcriptionEngine?.lastError = nil
            await services.sessionStore.startSession(sessionId: sid)
            apiServer.sessionDidStart(id: sid)
            do {
                try await services.transcriptLogger.startSession(
                    sourceApp: sourceApp,
                    vaultPath: outputPath,
                    sessionType: type,
                    suggestedFilename: suggestedFilename
                )
            } catch {
                await services.sessionStore.endSession()
                transcriptionEngine?.lastError = error.localizedDescription
                return
            }

            // Forward meeting context from API callers to the transcript
            if let ctx = meetingContext, let subject = ctx.subject {
                await services.transcriptLogger.updateContext(subject)
            }

            activeSessionType = type
            detectedAppName = resolvedAppName
            currentSessionId = sid
            currentSourceApp = sourceApp
            if type == .callCapture {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID,
                    appBundleID: appBundleID
                )
            } else {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID
                )
            }
        }
    }

    private func stopSession() {
        let wasCallCapture = activeSessionType == .callCapture
        let sessionId = currentSessionId ?? SessionStore.generateSessionId()
        let sourceApp = currentSourceApp ?? "Call"
        let sessionType: SessionType = wasCallCapture ? .callCapture : .voiceMemo

        activeSessionType = nil
        detectedAppName = nil
        silenceSeconds = 0
        currentSessionId = nil
        currentSourceApp = nil
        apiServer.sessionDidStop(id: sessionId)

        Task {
            // Snapshot the buffer URL BEFORE tearing down the engine, since the engine
            // may begin a new session (which reuses `SystemAudioCapture`) immediately.
            let bufferURL: URL? = wasCallCapture ? transcriptionEngine?.activeBufferURL : nil
            let wavWriteErrors = wasCallCapture ? (transcriptionEngine?.systemAudioWriteErrorCount ?? 0) : 0

            await transcriptionEngine?.stop()
            await services.sessionStore.endSession()
            guard let transcriptSnapshot = await services.transcriptLogger.endSession() else {
                transcriptionEngine?.assetStatus = "Ready"
                apiServer.sessionDidComplete(id: sessionId)
                return
            }

            // Build the immutable handle and hand it off to the background queue.
            // The engine and logger are now free for the next recording.
            let handle = SessionHandle(
                id: sessionId,
                sessionType: sessionType,
                sourceApp: sourceApp,
                wavBufferPath: bufferURL,
                transcript: transcriptSnapshot,
                wavWriteErrorCount: wavWriteErrors
            )
            let job = PostProcessingJob(
                handle: handle,
                clusterThreshold: Float(settings.diarizationClusterThreshold),
                numberOfSpeakers: settings.diarizationNumberOfSpeakers
            )

            services.postProcessingQueue.enqueue(job)
            transcriptionEngine?.assetStatus = "Ready"
        }
    }

    /// Fired from `onChange(of: services.postProcessingQueue.lastCompletion)`.
    /// Shows the save banner only if no new session is currently active; otherwise
    /// the active recording's UI takes precedence and a system notification handles it.
    private func handleJobCompleted(jobId: String, savedURL: URL, sessionType: SessionType) {
        apiServer.diarizationDidComplete()
        apiServer.sessionDidComplete(id: jobId)

        Task { await NotificationPresenter.shared.postCompletion(savedURL: savedURL, sessionType: sessionType) }

        if activeSessionType == nil {
            savedFileURL = savedURL
            bannerDismissTask?.cancel()
            bannerDismissTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { savedFileURL = nil }
            }
        }
    }

    private func handleNewUtterance() {
        guard let last = transcriptStore.utterances.last else { return }
        silenceSeconds = 0
        utteranceContinuation?.yield(UtteranceWrite(speaker: last.speaker, text: last.text, timestamp: last.timestamp))
    }
}
