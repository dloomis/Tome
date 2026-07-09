@preconcurrency import AVFoundation
import FluidAudio

/// Phase notifications from `ASRBackend.prepare`. The provisioner renders
/// `.downloading` with a percentage (nil = indeterminate) and `.loading` as
/// an indeterminate spinner — a bare (Double) -> Void callback couldn't
/// signal the download→load transition.
enum PrepareEvent: Sendable {
    case downloading(progress: Double?)
    case loading
}

/// One loadable ASR model. Conformances are actors: they own mutable SDK
/// handles (AsrManager / WhisperKit) that must be serialized.
///
/// AnyObject is load-bearing: ASRCoordinator tracks in-flight transcribe
/// calls per backend by ObjectIdentifier so a retired backend is only
/// unloaded after its last in-flight call returns (Swift actors are
/// reentrant — a swap can land while a transcribe is suspended mid-call).
protocol ASRBackend: AnyObject, Sendable {
    var model: TranscriberModel { get }
    /// True if everything needed for an offline load is on disk. For Whisper
    /// this includes BOTH the model folder AND the cached tokenizer.json.
    static func isInstalled() -> Bool
    /// Download (if needed) and load into memory. Emits `.loading`
    /// immediately when already installed.
    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws
    func transcribe(samples: [Float], language: Language) async throws -> ASRResult
    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult
    /// Release model memory. Called by ASRCoordinator only after the
    /// backend's last in-flight transcribe call has completed.
    func unload() async
}
