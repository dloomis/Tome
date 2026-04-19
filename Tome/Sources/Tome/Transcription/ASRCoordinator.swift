@preconcurrency import AVFoundation
import FluidAudio

/// Serializes all access to the shared `AsrManager`. Required because AsrManager holds
/// mutable per-source decoder state and `resetDecoderState()` resets BOTH mic and system
/// sources — concurrent live + batch transcriptions would race. Live streaming and
/// post-session segment re-transcription both route through this actor.
actor ASRCoordinator {
    private var asrManager: AsrManager?

    var isInitialized: Bool { asrManager != nil }

    /// Loads Parakeet-TDT v2 models and initializes the underlying `AsrManager`.
    /// Safe to call repeatedly — subsequent calls are no-ops.
    func initialize() async throws {
        guard asrManager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    /// Reset decoder state for both mic and system sources. Call at session start so
    /// stale context from a prior session doesn't leak into the new one.
    func resetDecoderState() async {
        try? await asrManager?.resetDecoderState()
    }

    func transcribe(samples: [Float], source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        return try await asrManager.transcribe(samples, source: source)
    }

    func transcribe(buffer: AVAudioPCMBuffer, source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        return try await asrManager.transcribe(buffer, source: source)
    }
}

enum ASRCoordinatorError: Error, Sendable {
    case notInitialized
}
