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

    init() {
        let asr = ASRCoordinator()
        self.asrCoordinator = asr
        self.postProcessingQueue = PostProcessingQueue(asr: asr)
        self.transcriptLogger = TranscriptLogger()
        self.sessionStore = SessionStore()
    }
}
