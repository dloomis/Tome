@preconcurrency import AVFoundation
import FluidAudio

/// Serializes all access to the shared `AsrManager`. FluidAudio 0.14 removed
/// AsrManager's internal decoder state and now requires the caller to thread
/// `decoderState: inout TdtDecoderState` through every transcribe call.
/// Each call gets a fresh state, matching FluidAudio 0.7.9's behavior where
/// `transcribe()` auto-reset decoder state after every call — Tome's
/// StreamingTranscriber hands the coordinator one VAD-bounded segment at a
/// time, so cross-call state carry-over would mean the LSTM/lastToken from a
/// previous utterance primes the decoder for an unrelated next utterance
/// (Parakeet v3 is sensitive enough that this collapses output to "."/blank).
/// All ASR — live `StreamingTranscriber` and batch `SegmentReTranscriber` —
/// routes through this actor.
actor ASRCoordinator {
    private var asrManager: AsrManager?
    /// Pushed in from `AppSettings.transcriptionLanguage` whenever it changes.
    /// Used by Parakeet v3 for script-aware token filtering (no-op on v2).
    private var currentLanguage: Language = .english

    var isInitialized: Bool { asrManager != nil }

    /// Update the language hint used by subsequent transcribe calls. Called from
    /// `ContentView` on appear and on settings change.
    func setLanguage(_ language: Language) {
        currentLanguage = language
    }

    /// Loads Parakeet-TDT v3 models and initializes the underlying `AsrManager`.
    /// Safe to call repeatedly — subsequent calls are no-ops.
    func initialize() async throws {
        guard asrManager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    /// No-op retained for API compatibility — decoder state is created fresh per call.
    func resetDecoderState() {}

    func transcribe(samples: [Float], source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(samples, decoderState: &state, language: currentLanguage)
    }

    func transcribe(buffer: AVAudioPCMBuffer, source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(buffer, decoderState: &state, language: currentLanguage)
    }
}

enum ASRCoordinatorError: Error, Sendable {
    case notInitialized
}
