import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

// The conferencing-app table lives in `MeetingDetector.swift` (`conferencingApps` /
// `conferencingAppName`) so detection and source-app labeling share one source of truth.

/// Pure stop-time helpers for `ContentView.stopSession`'s session-type
/// resolution (spec 2026-09-26 §3/§4). Kept out of the view so they can be
/// unit-tested without SwiftUI state; the ORDERING of the reads that feed them
/// is the hard part and lives (with its reasoning) in `stopSession`.
enum StopEvidence {
    /// `SessionTypeEvidence.themUtteranceCount`: final utterances attributed to
    /// "Them" whose text is not whitespace-only. "You" lines never count — the
    /// question is whether the FAR END said anything transcribable.
    nonisolated static func themUtteranceCount(in utterances: [Utterance]) -> Int {
        utterances.reduce(into: 0) { count, u in
            if u.speaker == .them,
               !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
    }

    /// The job's provisional-retype plan. Non-nil only for an `.auto` session
    /// that resolved to a voice memo: that note was written provisionally as a
    /// call and must be re-typed + moved. Explicit sessions were written as
    /// their final type from the start, and an `.auto` session that resolved
    /// as a call already IS a call note — both nil.
    ///
    /// An empty voice-folder setting re-types in place (`currentNoteFolder`)
    /// rather than aiming the move at a path-less URL (which resolves against
    /// the process cwd).
    ///
    /// The filename labels come from `intent` — snapshotted at START, the
    /// moment the provisional note was named — never from live settings: the
    /// job recognizes Tome's own default name by the call label that built it,
    /// so a mid-session label edit must not leak in.
    nonisolated static func retypePlan(
        intent: ActiveSessionIntent,
        resolvedType: SessionType,
        vaultVoicePath: String,
        currentNoteFolder: URL
    ) -> RetypePlan? {
        guard intent.mode == .auto, resolvedType == .voiceMemo else { return nil }
        let trimmed = vaultVoicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceFolder = trimmed.isEmpty
            ? currentNoteFolder
            : URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        return RetypePlan(
            voiceFolder: voiceFolder,
            voiceFilenameTypeLabel: intent.filenameVoiceLabel,
            callFilenameTypeLabel: intent.filenameCallLabel
        )
    }
}

/// Everything the in-flight session knew at START that `stopSession` needs,
/// captured once in `startSession` (alongside `activeSessionType`), consumed
/// and cleared once in `stopSession`, cleared in `rollbackFailedStart`. One
/// value instead of parallel `@State` fields, so the pieces can't drift out of
/// lockstep.
struct ActiveSessionIntent: Sendable, Equatable {
    /// What the session was started as. `.auto` = single Record button (or an
    /// API start with no `type`); resolved to a `SessionType` at stop.
    let mode: RecordingMode
    /// Resolver evidence (spec §3): the session began with a meeting name —
    /// API `meetingContext` / `suggestedFilename`, or an accepted
    /// MeetingDetector chip.
    let hadMeetingEvidence: Bool
    /// Resolver evidence (spec §3): a *native* conferencing app
    /// (`conferencingApps` family other than `.meetBrowser`) was frontmost at
    /// start. Browsers are deliberately excluded — Chrome frontmost during a
    /// phone-on-speaker call is the normal case, not call evidence.
    let nativeConferencingAppAtStart: Bool
    /// `settings.filenameCallLabel` as handed to `TranscriptLogger.startSession`
    /// — the label the provisional note was actually named with.
    let filenameCallLabel: String
    /// `settings.filenameVoiceLabel`, snapshotted at the same moment.
    let filenameVoiceLabel: String
}

struct ContentView: View {
    @Bindable var settings: AppSettings
    let apiServer: APIServer
    let services: AppServices
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var audioLevel: Float = 0
    /// Provisional type for `.auto` sessions (`.callCapture` until stop resolves
    /// it — spec §1), so every existing consumer keeps working unchanged.
    @State private var activeSessionType: SessionType?
    /// Start-time intent + evidence for the in-flight session (see
    /// `ActiveSessionIntent`). Set alongside `activeSessionType`; nil when idle.
    @State private var activeSessionIntent: ActiveSessionIntent?
    /// sessionId → `SessionTypeResolution.reasonLabel`, stashed by `stopSession`
    /// at resolution and consumed by `handleJobCompleted` for the save banner's
    /// tooltip (spec §7). Failure/discard drop their entry too.
    @State private var lastResolutionReason: [String: String] = [:]
    /// Tooltip for the save banner currently shown ("Filed as … (<reason>)").
    @State private var savedBannerHelp: String?
    @State private var detectedAppName: String?
    /// Latest passively-detected active meeting (Teams / Google Meet). Drives the
    /// pre-start naming chip. Nil when nothing is detected, screen-recording permission
    /// isn't granted, or a session is running.
    @State private var detectedMeeting: DetectedMeeting?
    /// Title the user explicitly dismissed (✕). Suppresses the chip for that exact
    /// meeting; a different title re-arms it. Cleared when a session ends.
    @State private var dismissedMeetingTitle: String?
    /// Meeting title applied to the in-flight session, shown in the Stop subtitle.
    @State private var activeMeetingTitle: String?
    @State private var silenceSeconds: Int = 0
    /// True while the silence stop-confirmation prompt (in-app + notification) is
    /// up. Recording continues until the user answers; cleared when audio resumes
    /// or the session ends. Replaces the old behavior of silently auto-stopping.
    @State private var silencePromptActive = false
    /// Confirmation gate for the main Stop button. `onConfirm` is wired to
    /// `stopSession()` in the boot task; the silence prompt, notification
    /// action, and HTTP API bypass it (see StopConfirmationModel).
    @State private var stopConfirmation = StopConfirmationModel()
    @State private var savedFileURL: URL?
    @State private var bannerDismissTask: Task<Void, Never>?
    /// Set when a short session was discarded (`AppSettings.discardShortMeetings`).
    /// In-app analogue of the save banner: the discard notification is skipped when
    /// permission is denied, and a transcript silently vanishing from the vault is
    /// exactly what this feature's messaging exists to prevent.
    @State private var discardNotice: String?
    @State private var discardDismissTask: Task<Void, Never>?
    @State private var sessionElapsed: Int = 0
    /// Identity of the session currently being captured, carried through to the
    /// `PostProcessingJob` at stop time so the job can be tracked by session id.
    @State private var currentSessionId: String?
    @State private var currentSourceApp: String?

    /// Single-shot guard: the orphan scan runs at most once per launch, fired
    /// either at the end of boot (no onboarding) or when onboarding dismisses.
    @State private var hasScannedOrphans = false

    /// A running mix-publishing mixer the user hasn't been told about yet
    /// (`MixerLeanInPrompt`). Drives the one-time lean-in invitation banner.
    /// Evaluated at boot and again when a known mixer launches while Tome is
    /// idle; never set while recording (starting a session clears it).
    @State private var leanInMixer: (bundleID: String, name: String)?

    /// Single-consumer channel that serializes utterance writes to the markdown
    /// transcript and the JSONL crash-recovery file. Prevents the two stores from
    /// drifting out of order when `handleNewUtterance` fires faster than the
    /// individual Task closures can run. `stopSession` awaits its `flush()`
    /// barrier before closing the session files.
    @State private var utteranceChannel: UtteranceWriteChannel?

    /// How many of `transcriptStore.utterances` have already been handed to the
    /// writer channel. `handleNewUtterance` drains everything past this cursor so a
    /// single `.onChange(of: utterances.count)` callback that covers *multiple*
    /// appended utterances (SwiftUI's `@Observable` coalesces same-tick mutations)
    /// persists all of them — the old `.last`-only yield silently dropped the
    /// earlier line(s). Reset to 0 whenever the store is cleared for a new session.
    @State private var persistedUtteranceCount = 0

    /// True while a conforming file drag hovers the window and importing is
    /// currently allowed. Drives the "Drop to import audio" overlay.
    @State private var importDropTargeted = false
    /// In-app line for an import that couldn't start or failed — the analogue of
    /// the discard notice, and independent of notification permission.
    @State private var importNotice: ImportNotice?
    @State private var importNoticeDismissTask: Task<Void, Never>?

    /// Text in the import status row's fallback slot. `isError` picks the
    /// styling: failures get the red warning treatment, informational notes
    /// (e.g. the one-file-at-a-time note) must not read as errors.
    private struct ImportNotice: Equatable {
        let message: String
        let isError: Bool
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

            // One-time invitation to point the call-audio source at a mixer mix.
            // Idle-only (evaluated at boot and on mixer launch) and never blocks
            // recording.
            if let mixer = leanInMixer, activeSessionType == nil {
                mixerLeanInBanner(bundleID: mixer.bundleID, name: mixer.name)
            }

            // Save banner (or the discard notice — never both; a discard writes nothing)
            if let url = savedFileURL, activeSessionType == nil {
                saveBanner(url: url)
            } else if let notice = discardNotice, activeSessionType == nil {
                discardBanner(notice)
            }

            // Import status / failure — its own slot, since an import can be in
            // flight while a previous session's save banner is still up.
            importStatusRow

            // Waveform ribbon
            WaveformView(isRecording: isRunning, audioLevel: audioLevel)

            // Glass control bar
            ControlBar(
                isRecording: isRunning,
                activeSessionType: activeSessionType,
                activeRequestedMode: activeSessionIntent?.mode,
                singleRecordButton: settings.singleRecordButton,
                audioLevel: audioLevel,
                detectedApp: detectedAppName,
                detectedMeetingName: suggestedMeeting?.title,
                activeMeetingTitle: activeMeetingTitle,
                silenceSeconds: silenceSeconds,
                silenceAutoStopSeconds: settings.silenceAutoStopSeconds,
                silencePromptActive: silencePromptActive,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError ?? modelFailureText,
                warningMessage: captureWarningMessage,
                hintMessage: transcriptionEngine?.micSilenceHintMessage,
                modelStatus: modelStatusText,
                canStartRecording: services.modelProvisioner.canStartRecording,
                onStartRecord: { startSession(mode: .auto, detectedMeeting: suggestedMeeting) },
                onStartCallCapture: { startSession(mode: .callCapture, detectedMeeting: suggestedMeeting) },
                onStartVoiceMemo: { startSession(mode: .voiceMemo) },
                onStopRequested: { stopConfirmation.requestStop() },
                onStop: stopSession,
                onKeepRecording: dismissSilencePrompt,
                onDismissMeeting: { dismissedMeetingTitle = detectedMeeting?.title }
            )
        }
        .frame(minWidth: 280, maxWidth: 360, minHeight: 400)
        .background(Color.bg0)
        .preferredColorScheme(.dark)
        .alert(
            "Are you sure you want to stop recording?",
            isPresented: Binding(
                get: { stopConfirmation.isPresented },
                set: { stopConfirmation.isPresented = $0 }
            )
        ) {
            // Cancel is the default (Return): the premise of this dialog is
            // that the stop was probably accidental, so the low-effort keys
            // must be the safe ones. Esc also cancels via the .cancel role.
            Button("Cancel", role: .cancel) { stopConfirmation.cancelStop() }
                .keyboardShortcut(.defaultAction)
            Button("Stop Recording", role: .destructive) { stopConfirmation.confirmStop() }
        }
        .onDrop(
            of: [.fileURL],
            delegate: ImportDropDelegate(
                isEnabled: canImportAudio,
                isTargeted: $importDropTargeted,
                onDrop: { urls in beginImport(urls) }
            )
        )
        .overlay {
            // Onboarding wins the overlay slot: the drop target is disabled
            // while it's up, so the two can't both be showing.
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            } else if importDropTargeted {
                importDropOverlay
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
            // scene (which can't see the engine) can show a recording indicator,
            // and into the APIServer so /health and the start/stop gates answer
            // off the MainActor.
            services.isRecording = running
            apiServer.updateIsRecording(running)
            // Session ended through another path (capture error, API stop,
            // notification stop) — withdraw a pending stop confirmation.
            if !running { stopConfirmation.recordingDidEnd() }
        }
        .onChange(of: services.modelProvisioner.canStartRecording, initial: true) { _, ready in
            // Mirror model readiness into the APIServer: /health's modelsReady
            // and the /start 503 gate must respond even while a modal alert or
            // panel has the MainActor parked in a nested run loop.
            apiServer.updateModelsReady(ready)
        }
        .onChange(of: settings.transcriptionLanguage) {
            // Push setting changes to the ASR actor so subsequent transcribe calls
            // use the new language hint. No UI for this setting yet — the hook is
            // here so the picker that lands next release works end-to-end.
            let language = settings.transcriptionLanguage
            Task { await services.asrCoordinator.setLanguage(language) }
        }
        .onChange(of: settings.transcriberModel) { _, model in
            // Mirrored by SettingsView.TranscriptionTab's onChange so a change
            // still provisions when this window is closed (F-4). provision() is
            // idempotent, so the duplicate call when both are live is a no-op.
            services.modelProvisioner.provision(model)
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

            // Kick provisioning of the selected model before anything that
            // needs ASR (notably the orphan scan at the end of this task,
            // which awaits the provisioner settling).
            services.modelProvisioner.provision(settings.transcriberModel)

            // No boot-time sanitize of the mic selection anymore: it's persisted
            // by device UID (stable across reboots/driver reloads), an absent
            // device renders as "(unavailable)" in the picker rather than a
            // blank selection, and the engine resolves UID → live ID at every
            // bind with a VISIBLE fallback when resolution fails.

            // Boot the single-consumer utterance writer so markdown + JSONL stay in lockstep.
            if utteranceChannel == nil {
                utteranceChannel = UtteranceWriteChannel(
                    logger: services.transcriptLogger,
                    store: services.sessionStore
                )
            }

            apiServer.register(
                transcriptStore: transcriptStore,
                transcriptionEngine: engine,
                sessionStore: services.sessionStore,
                onStart: { mode, sessionId, sessionGuid, context, filename in startSession(mode: mode, sessionId: sessionId, sessionGuid: sessionGuid, meetingContext: context, suggestedFilename: filename) },
                onStop: { stopSession() }
            )
            apiServer.start()

            services.saveTranscriptAction = { saveTranscriptToFile() }
            services.recoverFromWAVAction = { recoverFromWAV() }
            services.importAudioAction = { importAudio() }
            // The coordinator's §7 gate asks the app whether it's idle. Everything
            // else it needs (isRecording / isSessionPending / model readiness)
            // lives on AppServices; `activeSessionType` is ContentView's, and it
            // flips before `isRecording` does on the start path.
            services.importIdleProbe = { activeSessionType == nil }

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
            // Dialog "Stop Recording" → the real teardown. stopSession()'s
            // re-entrance guard makes a stale confirm (session already ended
            // by the API/notification in the same instant) a harmless no-op.
            stopConfirmation.onConfirm = { stopSession() }

            // Returning users: onboarding never shows, so we surface the orphan
            // prompt at the end of boot. First-launch users hit the onChange
            // handler when onboarding closes.
            if hasCompletedOnboarding {
                await checkForOrphanedSessionsOnce()
            }

            evaluateMixerLeanInPrompt()
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
        // Active-meeting detection (pre-start naming). Passive window-title scan via
        // SCShareableContent — uses the screen-recording permission Tome already holds
        // and never prompts (see MeetingDetector.scan). Idle-only; the chip is gated
        // on `suggestedMeeting`, which requires `!isRunning`.
        .task {
            while !Task.isCancelled {
                if !isRunning {
                    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let result = await MeetingDetector.scan(frontmostBundleID: front)
                    if result != detectedMeeting {
                        detectedMeeting = result
                        if let result { diagLog("[DETECT] \(result.appName) meeting detected") }
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Lean-in prompt, launch-driven: the boot evaluation misses the common
        // ordering where Tome (a login item) is up before the mixer starts, so
        // re-evaluate when a known mixer launches. Idle-only, and the same
        // one-shot guards apply (already prompted / source already configured),
        // so repeat launches are no-ops.
        .task {
            let launches = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didLaunchApplicationNotification)
                .compactMap { note in
                    (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                        .bundleIdentifier
                }
            for await bundleID in launches {
                guard MixerLeanInPrompt.isMixPublishingMixer(bundleID),
                      activeSessionType == nil else { continue }
                evaluateMixerLeanInPrompt()
            }
        }
        // One handler for all three import signals — SwiftUI type-checks this
        // body as a single expression, and three more `.onChange` modifiers
        // pushed it past the solver's budget.
        .onChange(of: importSignal) { old, new in
            // Poke the coordinator whenever the app's busy-ness changes, so a
            // file queued behind a recording starts the moment the app goes
            // idle (the coordinator's own retry poll is only a backstop).
            if old.isBusy != new.isBusy {
                services.importCoordinator.sessionStateDidChange()
            }
            if old.finishedCount != new.finishedCount {
                handleImportFinished()
            }
        }
        .onChange(of: settings.inputDeviceUID) {
            if isRunning {
                Task { await transcriptionEngine?.restartMic(inputDeviceUID: settings.inputDeviceUID) }
            }
        }
        .onChange(of: transcriptStore.utterances.count as Int) {
            handleNewUtterance()
        }
        .onChange(of: services.postProcessingQueue.lastCompletion) { _, new in
            guard let new else { return }
            handleJobCompleted(jobId: new.jobId, savedURL: new.savedURL, sessionType: new.sessionType)
        }
        .onChange(of: services.postProcessingQueue.lastFailure) { _, failure in
            guard let failure else { return }
            // Walk the API lifecycle out of `.transcribing` — without this a failed
            // job left /status reporting a transcription that would never finish.
            // The by-guid table records `failed` + the message for new pollers.
            apiServer.sessionDidFail(id: failure.jobId, message: failure.message)
            lastResolutionReason[failure.jobId] = nil
            // The WAVs were preserved; tell the user now, not at next launch.
            Task {
                await NotificationPresenter.shared.postJobFailure(
                    message: failure.message,
                    sessionType: failure.sessionType
                )
            }
            transcriptionEngine?.lastError = failure.message
        }
        .onChange(of: services.postProcessingQueue.lastDiscard) { _, discard in
            guard let discard else { return }
            // A discarded session still "finished" — walk the API lifecycle out of
            // `.transcribing` just like completion/failure, or /status would report a
            // transcription that never ends. By-guid pollers see `failed`: nothing
            // was written, so `complete` (with no transcript) would read as a bug.
            apiServer.sessionDidFail(id: discard.jobId, message: "Discarded: short recording (\(discard.durationSeconds)s ≤ threshold)")
            lastResolutionReason[discard.jobId] = nil
            // In-app signal FIRST, independent of notification permission — with
            // notifications denied the postDiscard below is silent, and the user
            // must still learn why the transcript isn't in the vault.
            discardNotice = "Short recording discarded (\(discard.durationSeconds)s) — at or under your discard threshold"
            discardDismissTask?.cancel()
            discardDismissTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { discardNotice = nil }
            }
            Task {
                await NotificationPresenter.shared.postDiscard(durationSeconds: discard.durationSeconds)
            }
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

        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Surface the failure — a silent `try?` here left the user believing
            // the export existed when the write bounced (read-only target, etc.).
            showAlert(
                title: "Couldn't save transcript",
                message: error.localizedDescription,
                style: .critical
            )
        }
    }

    /// Both capture-configuration warnings share the ControlBar's single amber
    /// line — they're independent (a fallback mic and a fallback call-audio
    /// source can be live at once) and each must stay visible.
    private var captureWarningMessage: String? {
        let warnings = [
            transcriptionEngine?.micFallbackMessage,
            transcriptionEngine?.systemSourceFallbackMessage,
        ].compactMap { $0 }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
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

            // Left-justified, immediately after the language label: anchored here
            // the toggles keep a fixed position, where trailing placement let the
            // status text's changing width (Ready / 0:07 / Finalizing…) slide them
            // back and forth once per second during a recording.
            HStack(spacing: 2) {
                topBarToggle(
                    symbol: "mic.slash",
                    isOn: transcriptionEngine?.micMuted ?? false,
                    activeTint: Color.recordRed,
                    help: "Mute microphone — Tome stops hearing and transcribing you"
                ) { transcriptionEngine?.micMuted.toggle() }
                .disabled(transcriptionEngine == nil)
                topBarToggle(
                    symbol: "eye.slash",
                    isOn: settings.hideFromScreenShare,
                    help: "Stealth mode — hide Tome from screen sharing and recording"
                ) { settings.hideFromScreenShare.toggle() }
                topBarToggle(
                    symbol: "pin",
                    isOn: settings.alwaysOnTop,
                    help: "Keep Tome on top of other windows"
                ) { settings.alwaysOnTop.toggle() }
            }
            .padding(.leading, 8)

            Spacer()

            HStack(spacing: 10) {
                Text(topBarStatus)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
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

    /// Compact icon-only toggle for the top bar (stealth / always-on-top) —
    /// the bar has no room for labels, so state reads through the filled
    /// symbol variant + tint, and the name lives in the tooltip.
    private func topBarToggle(
        symbol: String,
        isOn: Bool,
        activeTint: Color = Color.accent1,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? "\(symbol).fill" : symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? activeTint : Color.fg3)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? activeTint.opacity(0.15) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .help(help)
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
        // Resolution reason (spec §7: tooltip only). Empty = no tooltip.
        .help(savedBannerHelp ?? "")
    }

    // MARK: - Mixer lean-in prompt

    /// Decide whether to invite the user into device-backed call-audio capture.
    /// Runs at boot and again when a known mixer launches while idle. Invitation
    /// only — it never gates or delays recording, and automatic mode stays fully
    /// correct for anyone who dismisses it.
    private func evaluateMixerLeanInPrompt() {
        guard let bundleID = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: MixerLeanInPrompt.runningApplicationBundleIDs(),
            systemAudioSourceUID: settings.systemAudioSourceUID,
            alreadyPromptedBundleIDs: MixerLeanInPrompt.promptedBundleIDs()
        ) else { return }
        leanInMixer = (bundleID: bundleID, name: MixerLeanInPrompt.displayName(forBundleID: bundleID))
        diagLog("[LEAN-IN] mix-publishing mixer detected (\(bundleID)) — offering the call-audio source")
    }

    /// Same slot and styling as the save banner. The latch is set the moment the
    /// invitation is *shown*: it's a one-shot per mixer, so accepting and
    /// dismissing are both answers.
    private func mixerLeanInBanner(bundleID: String, name: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accent1.opacity(0.15))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accent1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) detected")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.fg1)
                Text("Tome can capture one of its mixes directly for cleaner call audio.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Button(action: { leanInMixer = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.fg3)
                }
                .buttonStyle(.plain)
                .help("Not now")
                SettingsLink {
                    Text("Set Up…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accent1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bg1.opacity(0.7))
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
        .onAppear {
            // Aim the Settings window at the source picker for as long as the
            // invitation is up, and burn the one-shot latch.
            services.settingsTab = .audio
            MixerLeanInPrompt.markPrompted(bundleID: bundleID)
        }
    }

    /// Save-banner variant for a discarded short session: same slot and styling,
    /// but nothing was written, so no open-file affordance.
    private func discardBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.fg2.opacity(0.15))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "trash")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.fg2)
                )
            Text(notice)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.fg1)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bg1.opacity(0.7))
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Import (spec: 2026-08-08 WAV import)

    /// The two things the body watches on behalf of imports, folded into one
    /// `Equatable` so a single `onChange` covers both.
    private struct ImportSignal: Equatable {
        let isBusy: Bool
        let finishedCount: Int
    }

    private var importSignal: ImportSignal {
        ImportSignal(
            isBusy: activeSessionType != nil || services.isSessionPending,
            finishedCount: services.importCoordinator.results.count
        )
    }

    /// Both entry points — the ⌘I menu item and drag-and-drop — gate on exactly
    /// this. The coordinator would happily queue a file and wait for the app to
    /// go idle, but silently accepting a drop mid-recording reads as nothing
    /// happening; refusing is the honest answer, and the drag gets the system's
    /// "not allowed" cursor for free.
    private var canImportAudio: Bool {
        // Must cover every term of `AppServices.importCanStart`: a gap between
        // the two gates lets a drop enqueue here and then wait forever on a
        // condition ("Waiting for the current recording…") that isn't the cause.
        !showOnboarding
            && activeSessionType == nil
            && !isRunning
            && !services.isSessionPending
            && !services.isRecovering
            && services.modelProvisioner.canStartRecording
    }

    /// Why `canImportAudio` is false, for the no-op path's error row.
    private var importUnavailableReason: String {
        if showOnboarding {
            return "Finish setting up Tome first, then import a recording."
        }
        if activeSessionType != nil || isRunning || services.isSessionPending {
            return "Stop the current recording before importing a file."
        }
        if services.isRecovering {
            return "Wait for the current recovery to finish before importing."
        }
        return "Transcription model not ready — check Settings ▸ Transcription"
    }

    /// `File ▸ Import Audio…` (⌘I). Registered into `AppServices` at boot rather
    /// than driven by an `@FocusedValue`, and the menu item stays statically
    /// enabled — see `CLAUDE.md` (Keyboard Shortcuts) for the macOS 26 crash.
    private func importAudio() {
        guard canImportAudio else {
            NSSound.beep()
            showImportNotice(importUnavailableReason)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.allowedContentTypes = ImportSupport.acceptedContentTypes
        // v1 is one file per gesture (§2). Flipping this is the v2 entry point —
        // `beginImport` and the coordinator are already list-shaped.
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        beginImport(panel.urls)
    }

    /// Funnel for both entry points. Resolves aliases, applies the cheap type
    /// gate, and hands the coordinator a list (one element in v1).
    private func beginImport(_ urls: [URL]) {
        guard canImportAudio else {
            NSSound.beep()
            showImportNotice(importUnavailableReason)
            return
        }
        let resolved = urls.map(Self.resolvedFileURL)
        let conforming = resolved.filter(ImportSupport.conformsToAcceptedType)
        guard let first = conforming.first else {
            NSSound.beep()
            showImportNotice("Tome can only import .wav recordings right now.")
            return
        }
        if resolved.count > 1 {
            // Worded to stay true after the import finishes too — the active-job
            // banner occupies the slot until then, so this often surfaces late.
            showImportNotice("Tome imports one file at a time — skipped all but \(first.lastPathComponent).", isError: false)
        } else {
            clearImportNotice()
        }
        services.importCoordinator.enqueue([first])
    }

    /// Follow an alias/symlink to the file the user actually meant. `NSOpenPanel`
    /// resolves aliases itself; a dropped item may not be resolved.
    private static func resolvedFileURL(_ url: URL) -> URL {
        if let real = try? URL(resolvingAliasFileAt: url, options: []) { return real }
        return url.resolvingSymlinksInPath()
    }

    /// One import reached a terminal state. Successes say nothing here — the
    /// handed-off `PostProcessingJob` drives the ordinary save banner and
    /// notification when it finishes, exactly as for a native memo.
    private func handleImportFinished() {
        guard let result = services.importCoordinator.lastResult,
              let message = result.message else { return }
        showImportNotice(message)
        // The window is often hidden behind whatever the user was doing; the
        // in-app row alone would go unseen. Same fallback shape as the
        // job-failure notification in `NotificationPresenter`.
        if !isMainWindowVisible {
            Task { await postImportFailureNotification(message) }
        }
    }

    private func showImportNotice(_ message: String, isError: Bool = true) {
        importNotice = ImportNotice(message: message, isError: isError)
        importNoticeDismissTask?.cancel()
        importNoticeDismissTask = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { importNotice = nil }
        }
    }

    private func clearImportNotice() {
        importNoticeDismissTask?.cancel()
        importNotice = nil
    }

    private var isMainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.title == "Tome" }
    }

    private func postImportFailureNotification(_ message: String) async {
        await NotificationPresenter.shared.requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Import failed"
        content.body = message
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        // Silently dropped when permission was denied — the in-app row above is
        // the permission-independent signal.
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Import UI

    /// Phase line + progress + Cancel while a file is importing; the waiting
    /// line while one is queued behind a recording; otherwise the last failure.
    @ViewBuilder
    private var importStatusRow: some View {
        if let job = services.importCoordinator.activeJob, !job.phase.isTerminal {
            importBanner(
                icon: "square.and.arrow.down",
                tint: Color.accent1,
                title: importPhaseTitle(job),
                progress: job.phase == .transcribing ? job.progressFraction : nil
            ) {
                Button("Cancel") {
                    services.importCoordinator.cancelActiveJob()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accent1)
            }
        } else if services.importCoordinator.isWaitingForIdle {
            importBanner(
                icon: "clock",
                tint: Color.fg2,
                title: "Waiting for the current recording to finish…",
                progress: nil
            ) {
                Button("Cancel") {
                    services.importCoordinator.cancelAll()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accent1)
            }
        } else if let notice = importNotice {
            importBanner(
                icon: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill",
                tint: notice.isError ? Color.recordRed : Color.fg2,
                title: notice.message,
                progress: nil
            ) {
                Button(action: { clearImportNotice() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.fg3)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private func importPhaseTitle(_ job: ImportJob) -> String {
        switch job.phase {
        case .queued, .validating:
            return "Validating…"
        case .preparing:
            return "Preparing…"
        case .transcribing:
            let percent = Int(job.progressFraction * 100)
            return "Transcribing “\(job.sourceStem)” (\(percent)%)"
        case .handedOff, .failed, .failedInternal, .cancelled:
            return job.displayName
        }
    }

    /// Same slot geometry and glass as the save/discard banners so the three
    /// never look like different mechanisms.
    private func importBanner<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        progress: Double?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint.opacity(0.15))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.fg1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(height: 2)
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bg1.opacity(0.7))
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    private var importDropOverlay: some View {
        ZStack {
            Color.bg0.opacity(0.85)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accent1)
                Text("Drop to import audio")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.fg1)
                Text("WAV recordings become voice memos.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accent1.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(8)
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Helpers

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    /// Main-screen provisioning banner (spec §7). Display-uppercased here;
    /// Settings shows the sentence-case versions.
    private var modelStatusText: String? {
        let provisioner = services.modelProvisioner
        switch provisioner.activity {
        case .downloading(_, let progress):
            if let progress { return "DOWNLOADING MODEL… \(Int(progress * 100))%" }
            return "DOWNLOADING MODEL…"
        case .loading:
            return "LOADING MODEL…"
        case .none:
            if provisioner.servingModel == nil, provisioner.lastFailure != nil {
                return "MODEL DOWNLOAD FAILED — retry in Settings ▸ Transcription"
            }
            if provisioner.servingModel != settings.transcriberModel {
                // Transient pre-kick / selection-write→onChange frames.
                return "LOADING MODEL…"
            }
            return nil
        }
    }

    /// Post-revert failure line (spec §7): shown while a failure is recorded
    /// AND something is serving (the F3 no-fallback case renders through
    /// modelStatusText instead).
    private var modelFailureText: String? {
        let provisioner = services.modelProvisioner
        guard let failure = provisioner.lastFailure,
              let serving = provisioner.servingModel else { return nil }
        return "\(failure.model.displayName) failed — reverted to \(serving.displayName): \(failure.message)"
    }

    /// The detected meeting to actually offer, after the global toggle, the per-meeting
    /// dismissal, and the not-recording gate. Nil → Call Capture uses the default label.
    private var suggestedMeeting: DetectedMeeting? {
        guard !isRunning, settings.useDetectedMeetingNames,
              let m = detectedMeeting, m.title != dismissedMeetingTitle else { return nil }
        return m
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

    /// Start a session. Explicit modes (`.callCapture` / `.voiceMemo`) map
    /// straight onto the two historical code paths. `.auto` (single Record
    /// button, API start with no `type`) runs the call-capture path — both legs,
    /// meetings folder, provisional `type: meeting` note — and its real type is
    /// resolved at stop (`SessionTypeResolver`, spec §1–§3).
    private func startSession(mode: RecordingMode, sessionId: String? = nil, sessionGuid: String? = nil, meetingContext: MeetingContext? = nil, suggestedFilename: String? = nil, detectedMeeting: DetectedMeeting? = nil) {
        // UI gating makes this unreachable from the buttons; API starts and
        // races land here. Surfaced via the same error row the UI already has.
        guard services.modelProvisioner.canStartRecording else {
            transcriptionEngine?.lastError = "Transcription model not ready — check Settings ▸ Transcription"
            return
        }
        // Lock model changes across the whole press → recording-live window —
        // it spans the awaits below AND `ensureMicrophonePermission()`'s TCC
        // prompt (minutes on first run), which `isRecording` doesn't cover
        // until the engine flips live. Cleared on EVERY exit of the Task below
        // (success, rollback, early return). Audit F-2.
        services.isSessionPending = true
        transcriptStore.clear()
        persistedUtteranceCount = 0  // new session — rewind the persistence cursor
        silenceSeconds = 0
        silencePromptActive = false
        sessionElapsed = 0
        savedFileURL = nil
        bannerDismissTask?.cancel()
        discardNotice = nil
        discardDismissTask?.cancel()

        let sid = sessionId ?? SessionStore.generateSessionId()
        // Uniform identity: API starts arrive with a guid (caller-supplied or
        // handler-minted); manual menu-bar starts mint here, so every session's
        // artifacts carry one.
        let guid = sessionGuid ?? UUID().uuidString.lowercased()

        // Determine output folder and source-app label based on session type. The
        // resolved conferencing app only labels the note (`source_app`) — system
        // audio is captured display-wide, not scoped to that app's process (see
        // SystemAudioCapture.bufferStream), so no bundle ID flows to the engine.
        //
        // `.auto` is written provisionally as a call (the ~95% case); a stop-time
        // voice-memo resolution re-types + moves the note in the job.
        let provisionalType: SessionType = mode.explicitSessionType ?? .callCapture
        let outputPath: String
        let sourceApp: String
        var resolvedAppName: String?

        // Frontmost app, read once: labels a call's `source_app` (browsers
        // included) and feeds the resolver's native-conferencing-app evidence
        // (browsers excluded — spec §3).
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let nativeConferencingApp = frontmostBundleID
            .flatMap { conferencingApps[$0] }
            .map { $0.family != .meetBrowser } ?? false

        switch provisionalType {
        case .callCapture:
            outputPath = settings.vaultMeetingsPath
            if let bundleID = frontmostBundleID,
               let appName = conferencingAppName(bundleID) {
                sourceApp = appName
                resolvedAppName = appName
            } else {
                sourceApp = "Call"
            }
        case .voiceMemo:
            outputPath = settings.vaultVoicePath
            sourceApp = "Voice Memo"
        }

        // Resolve the meeting name to apply. An API-supplied name always overrules what
        // Tome autodetected — and that must hold for the *displayed* title (driven by
        // effectiveContext.subject below), not just the resulting filename. The finalizer
        // names the file `suggestedFilename` → context(subject) → timestamp; so once the
        // API has supplied *any* name (a subject or a suggestedFilename), autodetection is
        // suppressed here too, keeping the on-screen title and the saved name in lockstep.
        // Autodetection only drives the title when the API named nothing at all.
        let apiNamePresent = meetingContext != nil || suggestedFilename != nil
        let effectiveContext: MeetingContext? = meetingContext
            ?? (apiNamePresent
                ? nil
                : detectedMeeting.map { MeetingContext(subject: $0.title, attendees: nil, calendarEventId: nil, startTime: nil) })
        // Resolver evidence (spec §3 rule 2): any meeting name at start — API
        // context/filename or an accepted detector chip.
        let hadMeetingEvidence = effectiveContext != nil || suggestedFilename != nil

        Task {
            transcriptionEngine?.lastError = nil
            await services.sessionStore.startSession(sessionId: sid)
            apiServer.sessionDidStart(
                id: sid,
                guid: guid,
                subject: effectiveContext?.subject,
                suggestedFilename: suggestedFilename
            )
            // Snapshot both filename labels at the moment the logger names the
            // provisional note; they ride in `ActiveSessionIntent` to stop so a
            // mid-session Settings edit can't make the retype mis-recognize
            // Tome's own default name.
            let filenameCallLabel = settings.filenameCallLabel
            let filenameVoiceLabel = settings.filenameVoiceLabel
            let transcriptURL: URL
            do {
                transcriptURL = try await services.transcriptLogger.startSession(
                    sourceApp: sourceApp,
                    vaultPath: outputPath,
                    sessionType: provisionalType,
                    sessionGuid: guid,
                    calendarEventId: meetingContext?.calendarEventId,
                    suggestedFilename: suggestedFilename,
                    filenameDateFormat: settings.filenameDateFormat,
                    filenameTypeLabel: provisionalType == .voiceMemo
                        ? filenameVoiceLabel
                        : filenameCallLabel
                )
            } catch {
                // Transcript note couldn't be created (vault unwritable, etc.). The
                // JSONL session and the API `.recording` state were already opened
                // above — unwind both so we don't strand a phantom recording. No UI
                // state was set yet (that happens after this point), and no note
                // exists to delete since startSession threw.
                await services.sessionStore.endSession()
                apiServer.sessionDidStop(id: sid)
                apiServer.sessionDidFail(id: sid, message: "Couldn't create the transcript: \(error.localizedDescription)")
                transcriptionEngine?.lastError = error.localizedDescription
                services.isSessionPending = false   // start aborted (F-2)
                return
            }

            // Apply the meeting context (API caller, else autodetected) to the transcript.
            if let subject = effectiveContext?.subject {
                await services.transcriptLogger.updateContext(subject)
            }

            activeSessionType = provisionalType
            activeSessionIntent = ActiveSessionIntent(
                mode: mode,
                hadMeetingEvidence: hadMeetingEvidence,
                nativeConferencingAppAtStart: nativeConferencingApp,
                filenameCallLabel: filenameCallLabel,
                filenameVoiceLabel: filenameVoiceLabel
            )
            // Starting a recording is an answer to the lean-in invitation too:
            // don't re-present it in the save-banner slot when this session ends.
            leanInMixer = nil
            detectedAppName = resolvedAppName
            activeMeetingTitle = effectiveContext?.subject
            currentSessionId = sid
            currentSourceApp = sourceApp

            let recordingContext = SessionRecordingContext(
                sessionId: sid,
                sessionGuid: guid,
                transcriptURL: transcriptURL,
                sourceApp: sourceApp,
                sessionType: provisionalType,
                startedAt: Date()
            )

            if provisionalType == .callCapture {
                // Call Capture and `.auto` — both legs, always (spec §2).
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceUID: settings.inputDeviceUID,
                    recordingContext: recordingContext,
                    excludedAudioAppIDs: settings.excludedAudioAppIDs,
                    systemAudioSourceUID: settings.systemAudioSourceUID
                )
            } else {
                // Voice memos / in-person meetings are mic-only: skip system-audio
                // capture so the mic is the sole source and post-session diarization
                // runs on the mic track (see PostProcessingJob).
                await transcriptionEngine?.start(
                    locale: settings.locale,
                    inputDeviceUID: settings.inputDeviceUID,
                    recordingContext: recordingContext,
                    captureSystemAudio: false
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
            // Start flow finished: either the engine is live (isRecording now
            // holds the lock) or we rolled back to idle. Release the pending
            // lock either way (F-2).
            services.isSessionPending = false
        }
    }

    /// Undo the bookkeeping `startSession` created before a `transcriptionEngine.start()`
    /// that failed to bring capture up. Mirrors the relevant parts of `stopSession`
    /// minus post-processing — there's nothing to finalize, just an empty note to
    /// discard and state to return to idle.
    @MainActor
    private func rollbackFailedStart(sessionId: String) async {
        // Belt-and-braces: if a stop raced the start's awaits, capture may have
        // been brought up for a session already considered dead. stop() is
        // idempotent and cheap on an already-stopped engine — but it clears
        // lastError, so snapshot the engine's explanation first and restore it.
        let startFailureReason = transcriptionEngine?.lastError
        await transcriptionEngine?.stop()
        transcriptionEngine?.lastError = startFailureReason ?? "Couldn't start recording."

        // Same drain-then-barrier as stopSession: if capture partially came up,
        // whatever was transcribed must reach the files before they close (and
        // the speakersDetected guard below relies on the logger having seen it).
        handleNewUtterance()
        await utteranceChannel?.flush()

        // Close the half-open transcript session and delete the empty note created
        // before the failed start. Guarded: only remove the note when no utterances
        // ever landed in it (speakersDetected is populated per-append) — if capture
        // partially came up before failing, whatever text made it to disk is kept.
        if let snapshot = await services.transcriptLogger.endSession(),
           snapshot.speakersDetected.isEmpty {
            try? FileManager.default.removeItem(at: snapshot.filePath)
        }
        await services.sessionStore.endSession()

        // Walk the API out of `.recording` back to idle (a bare sessionDidComplete
        // would stall, since it refuses to advance while state is `.recording`).
        // Recorded as `failed` in the by-guid table — nothing was produced.
        apiServer.sessionDidStop(id: sessionId)
        apiServer.sessionDidFail(id: sessionId, message: transcriptionEngine?.lastError ?? "Recording failed to start")

        // Return the UI to idle: the control bar shows Start, not Stop.
        activeSessionType = nil
        activeSessionIntent = nil
        detectedAppName = nil
        detectedMeeting = nil
        dismissedMeetingTitle = nil
        activeMeetingTitle = nil
        currentSessionId = nil
        currentSourceApp = nil
        silenceSeconds = 0
        silencePromptActive = false
        sessionElapsed = 0
    }

    private func stopSession() {
        // Re-entrance guard: a UI Stop racing an API /sessions/stop (both land on
        // the MainActor, so the first caller clears activeSessionType before the
        // second runs) must not tear down twice — the second pass would enqueue a
        // duplicate PostProcessingJob for the same transcript snapshot.
        guard activeSessionType != nil else {
            diagLog("[STOP] stopSession ignored — no active session")
            return
        }
        // Lock model changes across stop → job enqueued: `engine.stop()` flips
        // isRunning false several awaits before `enqueue`, and isAnyJobRunning
        // isn't true until the job actually starts, so this window is otherwise
        // unlocked. Cleared once the job is enqueued (or on early exit). F-2.
        services.isSessionPending = true
        let sessionId = currentSessionId ?? SessionStore.generateSessionId()
        let sourceApp = currentSourceApp ?? "Call"

        // ── Session-type resolution: start-time evidence (spec §3) ──────────
        // Everything the session knew at START is snapshotted here,
        // synchronously, before any await: the @State below is cleared a few
        // lines down, and once this function returns a new `startSession` may
        // overwrite it. `activeSessionIntent` is set for every live session
        // (explicit ones carry `.callCapture` / `.voiceMemo`); the nil fallback
        // is defensive only and derives the explicit mode from the provisional
        // type, so a nil can never turn an explicit session into `.auto`. The
        // fallback's labels are the live settings — harmless, since a non-auto
        // intent never produces a retype plan.
        let intent = activeSessionIntent ?? ActiveSessionIntent(
            mode: activeSessionType == .voiceMemo ? .voiceMemo : .callCapture,
            hadMeetingEvidence: false,
            nativeConferencingAppAtStart: false,
            filenameCallLabel: settings.filenameCallLabel,
            filenameVoiceLabel: settings.filenameVoiceLabel
        )
        let requestedMode = intent.mode
        // Settings consumed after resolution, snapshotted with the session they
        // belong to (a Settings edit during the stop awaits must not leak in).
        let vaultVoicePath = settings.vaultVoicePath
        let discardShortMeetings = settings.discardShortMeetings
        let discardShortMeetingSeconds = settings.discardShortMeetingSeconds

        activeSessionType = nil
        activeSessionIntent = nil
        detectedAppName = nil
        detectedMeeting = nil
        dismissedMeetingTitle = nil
        activeMeetingTitle = nil
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
            let audibleSystemBuffers = transcriptionEngine?.systemAudioAudibleBufferCount ?? 0
            // Which source the "Them" leg actually bound, so the empty-leg note
            // below points at the right thing to check.
            let systemFromDevice = transcriptionEngine?.systemAudioSourceIsDevice ?? false

            // ── Resolution evidence, engine side — read BEFORE `engine.stop()` ──
            // Same reasoning as the telemetry above: these are per-session
            // engine state, and the engine is reused by the next session the
            // moment stop() returns (the next start() resets the verdict and
            // re-routes the system-source accessors). Nothing between the top
            // of this Task and here awaits, so these still describe THIS
            // session. (stop() itself preserves both, but reading after it
            // would race a new start landing during the stop's own awaits.)
            //
            // `systemLegDelivered == false` is MISSING evidence (leg never bound
            // — permission declined, SCK failure, wedged HAL), which the
            // resolver treats as "fall back to call", never as silence.
            let systemLegDelivered = systemFirstSample != nil
            // Only meaningful for a device-backed leg; the engine already nils
            // it on SCK, the gate here keeps that contract local and explicit.
            let feederVerdict: FeederVerdict? = systemFromDevice
                ? transcriptionEngine?.systemLegFeederVerdict
                : nil

            await transcriptionEngine?.stop()

            // The engine drained the transcribers before returning, so every
            // final utterance — including the one flushed at stop — is now in
            // transcriptStore. But the write path to disk is still async:
            // SwiftUI's .onChange may not have ticked, and the writer channel
            // consumes in the background. Drain the cursor explicitly, then
            // barrier the channel so the markdown + JSONL appends land BEFORE
            // endSession() closes those files — an append after close is lost.
            handleNewUtterance()

            // ── Resolution evidence, store side — read AFTER the drain ──────
            // Why not earlier: the final "Them" utterance flushed at stop only
            // reaches `transcriptStore` inside `engine.stop()` (the system
            // transcriber's onFinal does `await MainActor.run { store.append }`
            // and stop() awaits that task). Counting before the drain makes a
            // call whose only far-end line was the last one resolve as a memo
            // (spec §3, rule 4).
            //
            // Why not later: `startSession` calls `transcriptStore.clear()`
            // SYNCHRONOUSLY, and every await between here and the handle is a
            // MainActor suspension point where a new start (UI or API) can run
            // and wipe the store. This line and `handleNewUtterance()` above
            // are back to back with no suspension between them, so the count
            // and the persisted cursor see the same store.
            //
            // Known, pre-existing window (not widened here): a new start that
            // lands DURING `engine.stop()` has already cleared the store by the
            // time we read it. That equally breaks `persistedUtteranceCount`
            // (the tail of this session never reaches disk) and predates the
            // resolver. It is narrow in practice: stop() holds the engine's
            // `isRunning` true until its very end, and both start paths gate on
            // it (ControlBar shows Stop while `isRecording`; the API start gate
            // refuses while its `isRecording` mirror is set). The wider window
            // is AFTER stop() returns — which is why nothing here awaits.
            let themUtteranceCount = StopEvidence.themUtteranceCount(in: transcriptStore.utterances)

            // Pure, no awaits: resolve now while all evidence is in hand.
            let evidence = SessionTypeEvidence(
                requestedMode: requestedMode,
                hasMeetingEvidence: intent.hadMeetingEvidence,
                nativeConferencingAppAtStart: intent.nativeConferencingAppAtStart,
                systemLegDelivered: systemLegDelivered,
                feederVerdict: feederVerdict,
                themUtteranceCount: themUtteranceCount
            )
            let resolution = SessionTypeResolver.resolveSessionType(evidence)
            diagLog(SessionTypeResolver.logLine(for: resolution, evidence: evidence))
            let sessionType = resolution.sessionType
            // Report to the API now, before the first await below. Ordering vs
            // `sessionDidStop` (called synchronously at the top, before this
            // Task): the resolution is only known here, after the drain, so it
            // necessarily lands AFTER the session moved to `transcribing`.
            // That's fine — `sessionDidResolve` keys by sessionId (and by-guid
            // via guidBySessionId), doesn't check state, and the stored value
            // survives `sessionDidStop`/`sessionDidComplete` until the 5s
            // post-completion eviction; /status only hides it while the state
            // is still `recording`. It must precede `sessionDidComplete` (the
            // nil-snapshot guard below and the job's completion) so the eviction
            // timer can't start first. A new start with the same second-granular
            // id clears it — the pre-existing id-collision caveat, not new here.
            apiServer.sessionDidResolve(id: sessionId, sessionType: sessionType, resolution: resolution.reasonLabel)
            lastResolutionReason[sessionId] = resolution.reasonLabel

            await utteranceChannel?.flush()

            await services.sessionStore.endSession()
            guard let transcriptSnapshot = await services.transcriptLogger.endSession() else {
                lastResolutionReason[sessionId] = nil   // no job → no banner
                transcriptionEngine?.assetStatus = "Ready"
                apiServer.sessionDidComplete(id: sessionId)
                services.isSessionPending = false   // nothing to enqueue (F-2)
                return
            }

            // Short-recording discard applies to call captures only (voice memos
            // are never dropped). Keyed on the RESOLVED type: an `.auto` session
            // that resolved to a memo (a 20-second phone call) must be as
            // un-discardable as an explicit memo. nil = the job's normal save path.
            let discardLimit: TimeInterval? = (sessionType == .callCapture && discardShortMeetings)
                ? TimeInterval(discardShortMeetingSeconds)
                : nil
            // Only an `.auto` session resolved to a memo was written provisionally
            // as a call note; the job re-types + relocates it first.
            let provisionalRetype = StopEvidence.retypePlan(
                intent: intent,
                resolvedType: sessionType,
                vaultVoicePath: vaultVoicePath,
                currentNoteFolder: transcriptSnapshot.filePath.deletingLastPathComponent()
            )

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
                mergeGapSeconds: settings.diarizationMergeGapSeconds,
                retention: retention,
                exportVoiceprints: settings.exportVoiceprints,
                discardIfShorterThanOrEqual: discardLimit,
                provisionalRetype: provisionalRetype
            )

            services.postProcessingQueue.enqueue(job)
            transcriptionEngine?.assetStatus = "Ready"
            // Job now running (isAnyJobRunning holds the lock); release the
            // stop-window pending lock (F-2).
            services.isSessionPending = false

            // End-of-session note for a session that captured a system leg (an
            // explicit call or `.auto`) whose leg carried no audible content at
            // all. Content-based, not delivery-based — SCStream delivers silent
            // buffers continuously, so this is the only signal that "Them" is
            // empty. Gated to sessions ≥60s so a quick test start/stop doesn't
            // nag; the fixed notification ID replaces the watchdog's mid-session
            // warning rather than stacking on it. Suppressed only for a memo
            // resolved BECAUSE the live leg was silent (`.farEndSilent`) — there
            // silence is the expected outcome. `.mixUnfed` still gets it (the
            // advice to launch the mixer is correct), as do explicit calls and
            // meeting/app-evidenced calls (the "is my mix wired?" case). §7.
            let capturedSystemLeg = requestedMode != .voiceMemo
            if capturedSystemLeg, audibleSystemBuffers == 0,
               let firstSample = micFirstSample ?? systemFirstSample,
               Date().timeIntervalSince(firstSample) >= 60 {
                if resolution.suppressesSilentLegNote {
                    diagLog("[STOP] silent-leg note suppressed — session resolved \(resolution.reasonLabel)")
                } else {
                    diagLog("[STOP] call capture ended with zero audible system-audio buffers — posting silent-leg note")
                    let detail = TranscriptionEngine.systemAudioSilentDetail(deviceMode: systemFromDevice, atStop: true)
                    Task { await NotificationPresenter.shared.postSystemAudioSilent(detail: detail) }
                }
            }
        }
    }

    /// Fired from `onChange(of: services.postProcessingQueue.lastCompletion)`.
    /// Shows the save banner only if no new session is currently active; otherwise
    /// the active recording's UI takes precedence and a system notification handles it.
    private func handleJobCompleted(jobId: String, savedURL: URL, sessionType: SessionType) {
        apiServer.diarizationDidComplete()
        apiServer.sessionDidComplete(id: jobId, savedURL: savedURL)

        Task { await NotificationPresenter.shared.postCompletion(savedURL: savedURL, sessionType: sessionType) }

        let reason = lastResolutionReason.removeValue(forKey: jobId)
        if activeSessionType == nil {
            savedFileURL = savedURL
            savedBannerHelp = reason.map {
                "Filed as \(sessionType == .callCapture ? "Meeting" : "Voice memo") (\($0))"
            }
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
        // Wait for provisioning to settle BEFORE taking the recovery lock — the
        // lock disables the picker AND Retry, the only affordances that could
        // cancel/redirect the very download we'd otherwise wait on (audit F-3).
        // No suspension point may sit between this returning and the flag below,
        // or a cycle could start inside the gap.
        await services.modelProvisioner.awaitSettled()
        services.isRecovering = true
        defer { services.isRecovering = false }

        let total = orphans.count
        var recovered = 0
        var failed: [String] = []

        for (idx, orphan) in orphans.enumerated() {
            transcriptionEngine?.assetStatus = "Recovering \(idx + 1) of \(total)…"

            guard let sidecar = orphan.sidecar else {
                failed.append("\(orphan.wavURL.lastPathComponent): no sidecar — use Cmd+Opt+R")
                continue
            }
            var transcriptURL = sidecar.transcriptURL
            if !FileManager.default.fileExists(atPath: transcriptURL.path) {
                // The sidecar path can go stale when the vault pipeline renames a
                // note before its session finalizes — the note is still findable
                // by its preserved `source_file:` frontmatter key.
                if let renamed = TranscriptFinalizer.relocateRenamedNote(from: transcriptURL) {
                    transcriptURL = renamed
                } else {
                    // Nothing to relocate — the note was deleted externally
                    // (incident 2026-07-23). Rebuild it from the session JSONL
                    // next to the WAV so diarization has a note to land in.
                    let jsonlURL = orphan.wavURL.deletingLastPathComponent()
                        .appendingPathComponent("\(sidecar.sessionId).jsonl")
                    do {
                        try TranscriptRebuilder.rebuildLiveNote(
                            jsonlURL: jsonlURL,
                            at: transcriptURL,
                            sessionType: sidecar.sessionType,
                            sourceApp: sidecar.sourceApp,
                            sessionGuid: sidecar.sessionGuid ?? "",
                            sessionStart: sidecar.startedAt
                        )
                    } catch {
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        failed.append("\(transcriptURL.lastPathComponent): transcript missing and JSONL rebuild failed (\(msg))")
                        continue
                    }
                }
            }

            do {
                _ = try await Recovery.run(
                    wavURL: orphan.wavURL,
                    transcriptURL: transcriptURL,
                    asr: services.asrCoordinator,
                    clusterThreshold: Float(settings.diarizationClusterThreshold),
                    numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                    mergeGapSeconds: settings.diarizationMergeGapSeconds,
                    exportVoiceprints: settings.exportVoiceprints,
                    // Mic-only orphans (voice memos): the WAV IS the mic, so keeping
                    // the live "You" lines would duplicate every word.
                    preserveYou: orphan.sidecar?.sessionType != .voiceMemo
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

        // A `.mic.wav` is ambiguous on the manual path (no sidecar): a voice
        // memo's primary track (rebuild replaces the body) or a call capture's
        // mic side (replacing the body would DESTROY every live "Them" line in
        // the note). Never guess on a destructive fork — ask.
        var preserveYou = true
        if wavURL.lastPathComponent.lowercased().hasSuffix(".mic.wav") {
            let kind = NSAlert()
            kind.messageText = "What kind of recording is this mic track?"
            kind.informativeText = """
                Voice memo / in-person: the transcript body is rebuilt entirely from this WAV.

                Call capture mic side: your "You" lines are rebuilt from this WAV and the note's existing "Them" lines are kept.
                """
            kind.alertStyle = .informational
            kind.addButton(withTitle: "Voice Memo / In-Person")
            kind.addButton(withTitle: "Call Capture (keep \"Them\")")
            kind.addButton(withTitle: "Cancel")
            switch kind.runModal() {
            case .alertFirstButtonReturn: preserveYou = false
            case .alertSecondButtonReturn: preserveYou = true
            default: return
            }
        }

        Task { [preserveYou] in
            // Settle provisioning BEFORE the recovery lock (F-3): the lock
            // disables the picker + Retry, the only ways to cancel/redirect a
            // download we'd otherwise be waiting on. No suspension between the
            // settle returning and taking the flag.
            await services.modelProvisioner.awaitSettled()
            services.isRecovering = true
            defer { services.isRecovering = false }

            let result: Result<URL, Error>
            do {
                let saved = try await Recovery.run(
                    wavURL: wavURL,
                    transcriptURL: mdURL,
                    asr: services.asrCoordinator,
                    clusterThreshold: Float(settings.diarizationClusterThreshold),
                    numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                    mergeGapSeconds: settings.diarizationMergeGapSeconds,
                    exportVoiceprints: settings.exportVoiceprints,
                    preserveYou: preserveYou
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
            utteranceChannel?.write(speaker: u.speaker, text: u.text, timestamp: u.timestamp)
        }
        persistedUtteranceCount = count
    }
}

// MARK: - Import drop target

/// A `DropDelegate` rather than the closure form of `.onDrop` because only
/// `validateDrop` can *refuse* a drag: returning false there is what makes the
/// system show the "not allowed" cursor over a PDF, a folder, or any drag while
/// a session is live — the closure form accepts everything and then discards it,
/// which reads to the user as Tome silently swallowing the file.
private struct ImportDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    /// List-shaped for v2 batch import; v1's handler takes the first conforming URL.
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // Both checks: a file URL that is also an accepted audio type. Without
        // the type term every drag (PDF, folder) gets the inviting overlay and
        // then a red error row — the refusal cursor is the honest answer.
        isEnabled
            && info.hasItemsConforming(to: [.fileURL])
            && info.hasItemsConforming(to: ImportSupport.acceptedContentTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard isEnabled else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            onDrop(urls)
        }
        return true
    }

    /// `loadObject(ofClass: URL.self)` is unavailable on a non-Sendable-checked
    /// path here; the data representation of a `public.file-url` is the URL's
    /// bookmark-free byte form, which `URL(dataRepresentation:)` reads directly.
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
