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

    init() {
        let asr = ASRCoordinator()
        self.asrCoordinator = asr
        self.postProcessingQueue = PostProcessingQueue(asr: asr)
    }
}
