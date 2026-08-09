import Foundation
import Observation

/// App-level singletons whose lifetime matches the app process. Lives in `TomeApp`
/// as @State and is injected into `ContentView`. Scenes outside of `ContentView`
/// (notably `MenuBarExtra`) also read from this so they can observe queue state.
@Observable
@MainActor
final class AppServices {
    /// Shared ASR serialization point. Wraps the underlying `AsrManager` so live
    /// streaming and background re-transcription coexist safely.
    let asrCoordinator: ASRCoordinator

    /// Background post-processing queue. Jobs are enqueued at stop time and run
    /// serially so new recordings can start immediately.
    let postProcessingQueue: PostProcessingQueue

    /// Live transcript writer (Markdown into the vault). App-lifetime so the
    /// terminate handler can reach it for an emergency flush.
    let transcriptLogger: TranscriptLogger

    /// Crash-recovery JSONL store. Same ownership rationale as `transcriptLogger`.
    let sessionStore: SessionStore

    /// Serial consumer for WAV imports. App-lifetime so a queued import survives
    /// the main window closing, and so `MenuBarExtra`/Settings can observe it.
    /// Deliberately does NOT own a `TranscriptLogger`/`SessionStore` — each job
    /// makes its own short-lived pair (spec §6.3); the app-lifetime instances
    /// above stay dedicated to live recording.
    let importCoordinator: ImportCoordinator

    /// True while a live recording/transcription session is in progress.
    /// `ContentView` mirrors `TranscriptionEngine.isRunning` into this so
    /// out-of-hierarchy scenes — notably the `MenuBarExtra` — can show a
    /// recording indicator. The engine itself lives in `ContentView`'s view
    /// state, where the menu bar scene can't reach it.
    var isRecording = false

    /// Action invoked by the `Save Transcript…` menu item. `ContentView` registers
    /// this in its boot task so the menu can fire it without going through
    /// `@FocusedValue` — that path triggers a main-menu rebuild on every focus
    /// change, which crashes inside `NSContextMenuImpl` on macOS 26. See
    /// `TomeApp.swift` and `CLAUDE.md` (Keyboard Shortcuts) for the rationale.
    @ObservationIgnored var saveTranscriptAction: (() -> Void)?

    /// Action invoked by the `Recover from WAV…` menu item. Same wiring rationale
    /// as `saveTranscriptAction` — `ContentView` registers it during boot.
    @ObservationIgnored var recoverFromWAVAction: (() -> Void)?

    /// Action invoked by the `Import Audio…` menu item. Same wiring rationale as
    /// `saveTranscriptAction` — `ContentView` registers it during boot and the
    /// callback itself no-ops (beep + error row) when import isn't possible.
    @ObservationIgnored var importAudioAction: (() -> Void)?

    /// Extra idle condition supplied by `ContentView`, which owns the session
    /// state the coordinator's §7 gate is written against (`activeSessionType`).
    /// Nil until boot registers it; absent, the flags on this object alone decide.
    @ObservationIgnored var importIdleProbe: (() -> Bool)?

    /// Which Settings tab the Settings window shows. Bound by `SettingsView`'s
    /// `TabView`, so anything that opens Settings can aim it — the mixer lean-in
    /// prompt sets `.audio` before opening so the user lands on the source picker.
    var settingsTab: SettingsTab = .general

    let modelProvisioner: ModelProvisioner

    /// True while orphan recovery or File ▸ Recover is re-transcribing.
    /// Settings uses it (with isRecording / isAnyJobRunning) to lock the
    /// model picker so a swap can't land mid-job.
    var isRecovering = false

    /// True during the session-transition windows that `isRecording` misses:
    /// press → recording actually running (which spans several awaits AND the
    /// first-run TCC microphone prompt — that modal can sit open for minutes),
    /// and stop → job enqueued. `isRecording` only flips once the engine is
    /// live and the onChange mirror lands, leaving those windows unlocked; a
    /// model swap starting there could install mid-session/mid-enqueue.
    /// Settings folds this into the picker lock to close that gap (audit F-2).
    var isSessionPending = false

    /// True while an import is validating, preparing or transcribing (spec §7).
    /// Bridged rather than mirrored: `ImportCoordinator` is `@Observable`, so
    /// reading through this property tracks its changes in any observing view —
    /// no `onChange` mirror to fall out of sync. Settings folds it into the
    /// model-picker lock so a backend swap can't land mid-import.
    var isImporting: Bool { importCoordinator.isImporting }

    init(settings: AppSettings) {
        let asr = ASRCoordinator()
        self.asrCoordinator = asr
        self.postProcessingQueue = PostProcessingQueue(asr: asr)
        self.transcriptLogger = TranscriptLogger()
        self.sessionStore = SessionStore()
        self.modelProvisioner = ModelProvisioner(
            coordinator: asr,
            selection: { settings.transcriberModel },
            setSelection: { settings.transcriberModel = $0 },
            makeBackend: { model in
                switch model {
                case .parakeetTDTv3: ParakeetBackend()
                case .whisperLargeV3Turbo: WhisperBackend()
                }
            }
        )

        // `isIdle` is the only coordinator closure that needs to read this
        // object's live state, and a strong capture would make services and
        // coordinator retain each other for the process lifetime. The box is a
        // stored property so it can be filled once `self` is fully initialized.
        let ref = ServicesRef()
        self.selfRef = ref
        let queue = self.postProcessingQueue
        self.importCoordinator = ImportCoordinator(
            pass: StreamingImportPass(asr: asr),
            environment: { [settings] in
                ImportEnvironment(
                    // Nil when Application Support is unusable — the coordinator
                    // then refuses the import. No temp-dir fallback: artifacts
                    // there are invisible to the orphan scan and crash recovery,
                    // so an interrupted import would be silently unrecoverable.
                    sessionsDirectory: try? SystemAudioCapture.sessionsDirectory(),
                    vaultPath: settings.vaultVoicePath,
                    filenameDateFormat: settings.filenameDateFormat,
                    filenameTypeLabel: settings.filenameVoiceLabel,
                    // A Tome artifact dropped back onto Tome (§5.4).
                    protectedDirectories: [
                        try? SystemAudioCapture.sessionsDirectory(),
                        settings.vaultVoiceURL,
                        settings.vaultMeetingsURL,
                        settings.recordingsFolderURL,
                    ].compactMap { $0 },
                    postProcessing: ImportPostProcessingOptions(
                        clusterThreshold: Float(settings.diarizationClusterThreshold),
                        numberOfSpeakers: settings.diarizationNumberOfSpeakers,
                        mergeGapSeconds: settings.diarizationMergeGapSeconds,
                        retention: settings.retainRecordings
                            ? settings.recordingsFolderURL.map(RecordingRetentionConfig.init(folder:))
                            : nil,
                        exportVoiceprints: settings.exportVoiceprints
                    )
                )
            },
            isIdle: { ref.services?.importCanStart ?? false },
            enqueuePostProcessing: { queue.enqueue($0) }
        )
        ref.services = self
    }

    /// Spec §7's gate, plus model readiness: a queued import that waits for the
    /// model to finish provisioning is better than one that fails on it. Every
    /// term is a *live* read — the coordinator calls this synchronously in the
    /// same main-actor block in which it commits to starting a job.
    private var importCanStart: Bool {
        guard !isRecording, !isSessionPending, !isRecovering else { return false }
        guard modelProvisioner.canStartRecording else { return false }
        // `ContentView.activeSessionType` flips before `isRecording` does on the
        // start path, and it is the property the spec names.
        return importIdleProbe?() ?? true
    }

    @ObservationIgnored private let selfRef: ServicesRef

    /// Breaks the services ↔ coordinator retain cycle (see `init`).
    @MainActor
    private final class ServicesRef {
        weak var services: AppServices?
    }
}
