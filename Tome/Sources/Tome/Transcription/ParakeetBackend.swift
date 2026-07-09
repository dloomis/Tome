@preconcurrency import AVFoundation
import FluidAudio

/// Parakeet-TDT v3 via FluidAudio.
///
/// Fresh `TdtDecoderState` per call is deliberate: FluidAudio 0.14 removed
/// AsrManager's internal decoder state and requires the caller to thread
/// `decoderState: inout TdtDecoderState` through every transcribe call. Each
/// call gets a fresh state, matching FluidAudio 0.7.9's behavior where
/// `transcribe()` auto-reset decoder state after every call — Tome's
/// StreamingTranscriber hands over one VAD-bounded segment at a time, so
/// cross-call state carry-over would mean the LSTM/lastToken from a previous
/// utterance primes the decoder for an unrelated next utterance (Parakeet v3
/// is sensitive enough that this collapses output to "."/blank).
final actor ParakeetBackend: ASRBackend {
    nonisolated let model: TranscriberModel = .parakeetTDTv3
    private var asrManager: AsrManager?

    static func isInstalled() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws {
        guard asrManager == nil else { return }
        if Self.isInstalled() { onEvent(.loading) }
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress in
            switch progress.phase {
            case .listing: onEvent(.downloading(progress: nil))
            case .downloading: onEvent(.downloading(progress: progress.fractionCompleted))
            case .compiling: onEvent(.loading)
            }
        })
        onEvent(.loading)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    func transcribe(samples: [Float], language: Language) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(samples, decoderState: &state, language: language)
    }

    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(buffer, decoderState: &state, language: language)
    }

    func unload() async {
        await asrManager?.cleanup()
        asrManager = nil
    }
}
