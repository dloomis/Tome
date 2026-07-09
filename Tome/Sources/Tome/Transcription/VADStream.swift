import FluidAudio

/// Speech boundary emitted by a streaming VAD.
enum VADEvent: Sendable {
    case speechStart
    case speechEnd
}

/// Seam over FluidAudio's streaming VAD so `StreamingTranscriber`'s
/// segmentation and stop-time flush logic can be tested without the silero
/// model. One instance carries the hysteresis state for one capture stream —
/// create a fresh one per `run()`.
protocol VADStream: Sendable {
    /// Process one VAD-sized chunk (4096 samples at 16kHz); returns a speech
    /// boundary event if one fired on this chunk.
    mutating func process(_ chunk: [Float]) async throws -> VADEvent?
}

/// Production implementation backed by FluidAudio's silero `VadManager`.
struct SileroVADStream: VADStream {
    private let manager: VadManager
    /// Created lazily on the first chunk (`makeStreamState` lives on the
    /// `VadManager` actor) so this initializer stays synchronous — the
    /// mid-session mic-restart path constructs transcribers without awaiting.
    private var state: VadStreamState?

    init(manager: VadManager) {
        self.manager = manager
    }

    mutating func process(_ chunk: [Float]) async throws -> VADEvent? {
        let currentState: VadStreamState
        if let state {
            currentState = state
        } else {
            currentState = await manager.makeStreamState()
        }
        let result = try await manager.processStreamingChunk(
            chunk,
            state: currentState,
            config: .default,
            returnSeconds: true,
            timeResolution: 2
        )
        state = result.state
        switch result.event?.kind {
        case .speechStart: return .speechStart
        case .speechEnd: return .speechEnd
        case nil: return nil
        }
    }
}
