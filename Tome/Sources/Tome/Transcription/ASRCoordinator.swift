@preconcurrency import AVFoundation
import FluidAudio

/// Serializes all access to the shared `AsrManager` and owns the per-source
/// `TdtDecoderState`. FluidAudio 0.14 removed AsrManager's internal per-source
/// state and now requires the caller to thread `decoderState: inout` through
/// every transcribe call. We keep one state per `AudioSource` so the
/// streaming chunk-by-chunk linguistic context (TdtDecoderState.lastToken) is
/// preserved across mid-utterance flushes — matching the pre-0.14 behavior.
/// All ASR — live `StreamingTranscriber` and batch `SegmentReTranscriber` —
/// routes through this actor.
actor ASRCoordinator {
    private var asrManager: AsrManager?
    private var micDecoderState = TdtDecoderState.make()
    private var systemDecoderState = TdtDecoderState.make()

    var isInitialized: Bool { asrManager != nil }

    /// Loads Parakeet-TDT v3 models and initializes the underlying `AsrManager`.
    /// Safe to call repeatedly — subsequent calls are no-ops.
    func initialize() async throws {
        guard asrManager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    /// Reset decoder state for both mic and system sources. Call at session start so
    /// stale context from a prior session doesn't leak into the new one.
    func resetDecoderState() {
        micDecoderState = TdtDecoderState.make()
        systemDecoderState = TdtDecoderState.make()
    }

    func transcribe(samples: [Float], source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        // Swift 6 prohibits passing an actor-isolated stored property `inout` across
        // an await suspension. Copy to a local, call, then write back — safe because
        // TdtDecoderState is a value type and the actor serializes access.
        var state = decoderState(for: source)
        let result = try await asrManager.transcribe(samples, decoderState: &state)
        setDecoderState(state, for: source)
        return result
    }

    func transcribe(buffer: AVAudioPCMBuffer, source: AudioSource) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = decoderState(for: source)
        let result = try await asrManager.transcribe(buffer, decoderState: &state)
        setDecoderState(state, for: source)
        return result
    }

    private func decoderState(for source: AudioSource) -> TdtDecoderState {
        switch source {
        case .microphone: return micDecoderState
        case .system: return systemDecoderState
        }
    }

    private func setDecoderState(_ state: TdtDecoderState, for source: AudioSource) {
        switch source {
        case .microphone: micDecoderState = state
        case .system: systemDecoderState = state
        }
    }
}

enum ASRCoordinatorError: Error, Sendable {
    case notInitialized
}
