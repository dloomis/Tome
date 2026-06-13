import SwiftUI
import AppKit

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
    /// True while the silence stop-confirmation prompt (in-app + notification) is
    /// up. Recording continues until the user answers; cleared when audio resumes
    /// or the session ends. Replaces the old behavior of silently auto-stopping.
    @State private var silencePromptActive = false
    @State private var savedFileURL: URL?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var sessionElapsed: Int = 0
    /// Identity of the session currently being captured, carried through to the
    /// `PostProcessingJob` at stop time so the job can be tracked by session id.
    @State private var currentSessionId: String?
    @State private var currentSourceApp: String?

    /// Single-shot guard: the orphan scan runs at most once per launch, fired
    /// either at the end of boot (no onboarding) or when onboarding dismisses.
    @State private var hasScannedOrphans = false

    /// Single-consumer channel that serializes utterance writes to the markdown
    /// transcript and the JSONL crash-recovery file. Prevents the two stores from
    /// drifting out of order when `handleNewUtterance` fires faster than the
    /// individual Task closures can run.
    @State private var utteranceContinuation: AsyncStream<UtteranceWrite>.Continuation?
    @State private var utteranceWriterTask: Task<Void, Never>?

    /// How many of `transcriptStore.utterances` have already been handed to the
    /// writer channel. `handleNewUtterance` drains everything past this cursor so a
    /// single `.onChange(of: utterances.count)` callback that covers *multiple*
    /// appended utterances (SwiftUI's `@Observable` coalesces same-tick mutations)
    /// persists all of them — the old `.last`-only yield silently dropped the
    /// earlier line(s). Reset to 0 whenever the store is cleared for a new session.
    @State private var persistedUtteranceCount = 0

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
                silencePromptActive: silencePromptActive,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                onStartCallCapture: { startSession(type: .callCapture) },
                onStartVoiceMemo: { startSession(type: .voiceMemo) },
                onStop: stopSession,
                onKeepRecording: dismissSilencePrompt
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
                // First-launch path: onboarding just dismissed; safe to surface
                // the orphan recovery prompt without overlapping dialogs.
                Task { await checkForOrphanedSessionsOnce() }
            }
        }
        .onChange(of: transcriptionEngine?.isRunning ?? false) { _, running in
            // Mirror live recording state into AppServices so the MenuBarExtra
            // scene (which can't see the engine) can show a recording indicator.
            services.isRecording = running
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

            services.saveTranscriptAction = { saveTranscriptToFile() }
            services.recoverFromWAVAction = { recoverFromWAV() }

            // Silence stop prompt — the notification's action buttons mirror the
            // in-app prompt so it's answerable while the Tome window is hidden
            // behind the meeting app. Guarded: a stale notification (already
            // answered in-app, or from a session that ended) must be a no-op.
            NotificationPresenter.shared.silenceStopAction = {
                if silencePromptActive { stopSession() }
            }
            NotificationPresenter.shared.silenceKeepAction = {
                if silencePromptActive { dismissSilencePrompt() }
            }

            // Returning users: onboarding never shows, so we surface the orphan
            // prompt at the end of boot. First-launch users hit the onChange
            // handler when onboarding closes.
            if hasCompletedOnboarding {
                await checkForOrphanedSessionsOnce()
            }
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
                        // Audio resumed — the silence premise is gone, so the
                        // pending stop confirmation withdraws itself.
                        if silencePromptActive { dismissSilencePrompt() }
                    }
                } else if audioLevel != 0 {
                    audioLevel = 0
                }
            }
        }
        // Silence stop-confirmation + elapsed timer
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard isRunning else {
                    silenceSeconds = 0
                    // Defensive: if the engine stopped through some path other
                    // than stopSession() (e.g. a capture error), don't leave a
                    // stale prompt up.
                    if silencePromptActive { dismissSilencePrompt() }
                    continue
                }
                sessionElapsed += 1
                apiServer.sessionElapsed = sessionElapsed
                if audioLevel < 0.01 {
                    silenceSeconds += 1
                    let limit = settings.silenceAutoStopSeconds
                    if limit > 0 && silenceSeconds >= limit && !silencePromptActive {
                        // Silence limit reached — never stop silently. Keep
                        // recording and ask the user to confirm.
                        presentSilencePrompt()
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
    }

    private func saveTranscriptToFile() {
        guard !transcriptStore.utterances.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Transcript.md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Offsets relative to the first utterance (no session-start handle on this
        // ad-hoc save path); same decimal-seconds format as the vault transcripts.
        let start = transcriptStore.utterances.first?.timestamp ?? Date()

        var md = "# Transcript\n\n"
        for u in transcriptStore.utterances {
            let speaker = u.speaker == .you ? "You" : "Them"
            let offset = u.timestamp.timeIntervalSince(start)
            md += "**\(speaker)** (\(formatTimeOffset(offset)))\n"
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

    /// Silence limit reached. The old behavior was a silent `stopSession()`;
    /// now the session keeps recording and asks — an in-app prompt in the
    /// control bar plus an actionable notification for when the window is
    /// hidden behind the meeting app.
    private func presentSilencePrompt() {
        silencePromptActive = true
        let elapsed = silenceSeconds
        Task { await NotificationPresenter.shared.postSilencePrompt(silentForSeconds: elapsed) }
    }

    /// Withdraw the silence prompt and restart the silence window — fired by
    /// the "Keep Recording" buttons (in-app and notification) and automatically
    /// when audio resumes. The prompt re-arms after another full silence period.
    private func dismissSilencePrompt() {
        silencePromptActive = false
        silenceSeconds = 0
        NotificationPresenter.shared.clearSilencePrompt()
    }

    private func startSession(type: SessionType, sessionId: String? = nil, meetingContext: MeetingContext? = nil, suggestedFilename: String? = nil) {
        transcriptStore.clear()
        persistedUtteranceCount = 0  // new session — rewind the persistence cursor
        silenceSeconds = 0
        silencePromptActive = false
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
            let transcriptURL: URL
            do {
                transcriptURL = try await services.transcriptLogger.startSession(
                    sourceApp: sourceApp,
                    vaultPath: outputPath,
                    sessionType: type,
                    suggestedFilename: suggestedFilename,
                    filenameDateFormat: settings.filenameDateFormat,
                    filenameTypeLabel: type == .voiceMemo
                        ? settings.filenameVoiceLabel
                        : settings.filenameCallLabel
                )
            } catch {
                // Transcript note couldn't be created (vault unwritable, etc.). The
                // JSONL session and the API `.recording` state were already opened
                // above — unwind both so we don't strand a phantom recording. No UI
                // state was set yet (that happens after this point), and no note
                // exists to delete since startSession threw.
                await services.sessionStore.endSession()
                apiServer.sessionDidStop(id: sid)
                apiServer.sessionDidComplete(id: sid)
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

            let recordingContext = SessionRecordingContext(
                sessionId: sid,
                transcriptURL: transcriptURL,
                sourceApp: sourceApp,
                sessionType: type,
                startedAt: Date()
            )

            if type == .callCapture {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID,
                    appBundleID: appBundleID,
                    recordingContext: recordingContext
                )
            } else {
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceID: settings.inputDeviceID,
                    recordingContext: recordingContext
                )
            }

            // `engine.start()` returns without throwing even when capture never came
            // up (mic permission denied, model-load failure — both leave isRunning
            // false). Everything above provisioned session bookkeeping ahead of the
            // start; unwind it so a failed start doesn't strand an open JSONL session,
            // an empty vault note, and a recording-state API/UI with nothing behind them.
            if transcriptionEngine?.isRunning != true {
                await rollbackFailedStart(sessionId: sid)
            }
        }
    }

    /// Undo the bookkeeping `startSession` created before a `transcriptionEngine.start()`
    /// that failed to bring capture up. Mirrors the relevant parts of `stopSession`
    /// minus post-processing — there's nothing to finalize, just an empty note to
    /// discard and state to return to idle.
    @MainActor
    private func rollbackFailedStart(sessionId: String) async {
        // The engine sets `lastError` on its hard-fail paths; keep a fallback in case
        // a future path forgets, so the control bar always explains the no-op.
        if transcriptionEngine?.lastError == nil {
            transcriptionEngine?.lastError = "Couldn't start recording."
        }

        // Close the half-open transcript session and delete the empty note created
        // before the failed start — no utterances landed, so there's nothing to keep.
        if let snapshot = await services.transcriptLogger.endSession() {
            try? FileManager.default.removeItem(at: snapshot.filePath)
        }
        await services.sessionStore.endSession()

        // Walk the API out of `.recording` back to idle (a bare sessionDidComplete
        // would stall, since it refuses to advance while state is `.recording`).
        apiServer.sessionDidStop(id: sessionId)
        apiServer.sessionDidComplete(id: sessionId)

        // Return the UI to idle: the control bar shows Start, not Stop.
        activeSessionType = nil
        detectedAppName = nil
        currentSessionId = nil
        currentSourceApp = nil
        silenceSeconds = 0
        silencePromptActive = false
        sessionElapsed = 0
    }

    private func stopSession() {
        let wasCallCapture = activeSessionType == .callCapture
        let sessionId = currentSessionId ?? SessionStore.generateSessionId()
        let sourceApp = currentSourceApp ?? "Call"
        let sessionType: SessionType = wasCallCapture ? .callCapture : .voiceMemo

        activeSessionType = nil
        detectedAppName = nil
        silenceSeconds = 0
        silencePromptActive = false
        NotificationPresenter.shared.clearSilencePrompt()
        currentSessionId = nil
        currentSourceApp = nil
        apiServer.sessionDidStop(id: sessionId)

        let retention = settings.retainRecordings
            ? settings.recordingsFolderURL.map(RecordingRetentionConfig.init(folder:))
            : nil

        Task {
            // Snapshot capture state BEFORE tearing down the engine, since the engine
            // may begin a new session (which reuses the capture objects) immediately.
            // The system WAV + mic WAV are snapshotted for all session types so the job
            // can both retain (when enabled) and clean them up — gating diarization on
            // `sessionType`, not on the presence of a buffer path.
            let bufferURL = transcriptionEngine?.activeBufferURL
            let micBufferURL = transcriptionEngine?.activeMicBufferURL
            let micFirstSample = transcriptionEngine?.micFirstSampleTime
            let systemFirstSample = transcriptionEngine?.systemFirstSampleTime
            let wavWriteErrors = transcriptionEngine?.systemAudioWriteErrorCount ?? 0

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
                micWavPath: micBufferURL,
                micFirstSampleTime: micFirstSample,
                systemFirstSampleTime: systemFirstSample,
                transcript: transcriptSnapshot,
                wavWriteErrorCount: wavWriteErrors
            )
            let job = PostProcessingJob(
                handle: handle,
                clusterThreshold: Float(settings.diarizationClusterThreshold),
                numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                retention: retention,
                exportVoiceprints: settings.exportVoiceprints
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

    /// Surface leftover recordings from a previous launch (typically a crash or
    /// force-quit). At most once per launch — gated by `hasScannedOrphans`. Runs
    /// after boot init so `services.asrCoordinator` is reachable.
    @MainActor
    private func checkForOrphanedSessionsOnce() async {
        guard !hasScannedOrphans else { return }
        hasScannedOrphans = true

        // Skip if a session is somehow already running (defensive — shouldn't
        // happen on a fresh launch, but recording + recovery on the same ASR
        // would race).
        if transcriptionEngine?.isRunning == true { return }

        let orphans = OrphanScanner.findOrphans()
        guard !orphans.isEmpty else { return }
        diagLog("[ORPHAN-SCAN] found \(orphans.count) orphan(s)")

        let alert = NSAlert()
        alert.messageText = orphans.count == 1
            ? "Tome found 1 unfinished recording"
            : "Tome found \(orphans.count) unfinished recordings"

        var lines = orphans.prefix(5).map { "• \($0.summaryLine)" }
        if orphans.count > 5 {
            lines.append("• …and \(orphans.count - 5) more")
        }
        alert.informativeText = """
        These recordings were left over from a session that didn't finish processing — likely a crash, force-quit, or post-processing failure.

        \(lines.joined(separator: "\n"))

        Recovery re-runs diarization on each WAV and updates its transcript.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: orphans.count == 1 ? "Recover" : "Recover All")
        alert.addButton(withTitle: "Decide Later")
        alert.addButton(withTitle: "Discard All")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await recoverOrphans(orphans)
        case .alertThirdButtonReturn:
            confirmAndDiscardOrphans(orphans)
        default:
            break  // Decide Later
        }
    }

    @MainActor
    private func recoverOrphans(_ orphans: [OrphanScanner.Orphan]) async {
        let total = orphans.count
        var recovered = 0
        var failed: [String] = []

        for (idx, orphan) in orphans.enumerated() {
            transcriptionEngine?.assetStatus = "Recovering \(idx + 1) of \(total)…"

            guard let sidecar = orphan.sidecar else {
                failed.append("\(orphan.wavURL.lastPathComponent): no sidecar — use Cmd+Opt+R")
                continue
            }
            let transcriptURL = sidecar.transcriptURL
            if !FileManager.default.fileExists(atPath: transcriptURL.path) {
                failed.append("\(transcriptURL.lastPathComponent): transcript file missing")
                continue
            }

            do {
                _ = try await Recovery.run(
                    wavURL: orphan.wavURL,
                    transcriptURL: transcriptURL,
                    asr: services.asrCoordinator,
                    clusterThreshold: Float(settings.diarizationClusterThreshold),
                    numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                    exportVoiceprints: settings.exportVoiceprints
                )
                OrphanScanner.discard(orphan)
                recovered += 1
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failed.append("\(transcriptURL.lastPathComponent): \(msg)")
            }
        }

        transcriptionEngine?.assetStatus = "Ready"

        let done = NSAlert()
        done.messageText = "Recovery complete"
        var info = "\(recovered) of \(total) recovered."
        if !failed.isEmpty {
            info += "\n\nFailed:\n" + failed.joined(separator: "\n")
            info += "\n\nFiles were left in place so you can retry via File → Recover from WAV…"
        }
        done.informativeText = info
        done.alertStyle = failed.isEmpty ? .informational : .warning
        done.addButton(withTitle: "OK")
        done.runModal()
    }

    @MainActor
    private func confirmAndDiscardOrphans(_ orphans: [OrphanScanner.Orphan]) {
        let alert = NSAlert()
        alert.messageText = orphans.count == 1
            ? "Discard 1 unfinished recording?"
            : "Discard \(orphans.count) unfinished recordings?"
        alert.informativeText = "This permanently deletes the WAV files. The transcripts (with un-diarized \"Them\" lines) stay in your vault."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for orphan in orphans {
            OrphanScanner.discard(orphan)
        }
    }

    /// User-driven recovery of an orphaned session via `Cmd+Opt+R`. Picks a WAV
    /// and an existing transcript .md, then re-runs diarization → re-transcription
    /// → body rebuild. See `Recovery.swift` for the pipeline rationale.
    private func recoverFromWAV() {
        if transcriptionEngine?.isRunning == true {
            showAlert(
                title: "Stop the current recording first",
                message: "Recovery uses the same ASR model as the live recorder — please stop the active session before recovering an orphaned WAV.",
                style: .warning
            )
            return
        }
        if services.postProcessingQueue.isAnyJobRunning {
            showAlert(
                title: "Finalization in progress",
                message: "A previous session is still being finalized. Wait a moment and try again.",
                style: .warning
            )
            return
        }

        let wavPanel = NSOpenPanel()
        wavPanel.title = "Choose the orphaned WAV"
        wavPanel.allowedContentTypes = [.wav]
        wavPanel.allowsMultipleSelection = false
        wavPanel.canChooseDirectories = false
        wavPanel.directoryURL = FileManager.default.temporaryDirectory
        guard wavPanel.runModal() == .OK, let wavURL = wavPanel.url else { return }

        let wavInfo: Recovery.WAVInfo
        do {
            wavInfo = try Recovery.inspectWAV(wavURL)
        } catch {
            showAlert(title: "WAV unreadable", message: error.localizedDescription, style: .critical)
            return
        }

        let mdPanel = NSOpenPanel()
        mdPanel.title = "Choose the orphaned transcript"
        mdPanel.allowedContentTypes = [.plainText]
        mdPanel.allowsMultipleSelection = false
        mdPanel.canChooseDirectories = false
        if let meetingsURL = settings.vaultMeetingsURL {
            mdPanel.directoryURL = meetingsURL
        }
        guard mdPanel.runModal() == .OK, let mdURL = mdPanel.url else { return }

        let durMin = Int(wavInfo.durationSeconds) / 60
        let durSec = Int(wavInfo.durationSeconds) % 60
        let sizeMB = Double(wavInfo.sizeBytes) / 1_048_576

        let confirm = NSAlert()
        confirm.messageText = "Recover this session?"
        confirm.informativeText = """
            WAV: \(wavURL.lastPathComponent)
            Duration: \(durMin):\(String(format: "%02d", durSec)) · Size: \(String(format: "%.0f", sizeMB)) MB

            Transcript: \(mdURL.lastPathComponent)

            Diarization + re-transcription will rewrite the transcript body and update the duration field. Frontmatter outside `duration:` is preserved.
            """
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Recover")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        transcriptionEngine?.assetStatus = "Recovering…"
        transcriptionEngine?.lastError = nil

        Task {
            let result: Result<URL, Error>
            do {
                let saved = try await Recovery.run(
                    wavURL: wavURL,
                    transcriptURL: mdURL,
                    asr: services.asrCoordinator,
                    clusterThreshold: Float(settings.diarizationClusterThreshold),
                    numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                    exportVoiceprints: settings.exportVoiceprints
                )
                result = .success(saved)
            } catch {
                result = .failure(error)
            }

            transcriptionEngine?.assetStatus = "Ready"

            switch result {
            case .success(let savedURL):
                let done = NSAlert()
                done.messageText = "Recovery complete"
                done.informativeText = "\(savedURL.lastPathComponent) was re-transcribed with speaker labels.\n\nDelete the WAV (\(String(format: "%.0f", sizeMB)) MB) now?"
                done.alertStyle = .informational
                done.addButton(withTitle: "Delete WAV")
                done.addButton(withTitle: "Keep")
                done.addButton(withTitle: "Show in Finder")
                let response = done.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    try? FileManager.default.removeItem(at: wavURL)
                case .alertThirdButtonReturn:
                    NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: savedURL.deletingLastPathComponent().path)
                default:
                    break
                }
            case .failure(let error):
                showAlert(
                    title: "Recovery failed",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    style: .critical
                )
                transcriptionEngine?.lastError = "Recovery failed: \(error.localizedDescription)"
            }
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func handleNewUtterance() {
        let count = transcriptStore.utterances.count
        // Defensive: the store shrank out from under us (cleared without going
        // through startSession). Rewind so we never index past the end.
        if count < persistedUtteranceCount { persistedUtteranceCount = 0 }
        guard count > persistedUtteranceCount else { return }

        silenceSeconds = 0
        // Speech evidence cancels a pending silence stop prompt, same as raw audio.
        if silencePromptActive { dismissSilencePrompt() }

        // Drain every utterance since the cursor, not just the last one. Two
        // utterances can land in a single update tick (mic + system finalizing
        // back-to-back); `.onChange(of: count)` then fires once, and yielding only
        // `.last` lost the earlier line from both the markdown and JSONL files.
        for index in persistedUtteranceCount..<count {
            let u = transcriptStore.utterances[index]
            utteranceContinuation?.yield(UtteranceWrite(speaker: u.speaker, text: u.text, timestamp: u.timestamp))
        }
        persistedUtteranceCount = count
    }
}
