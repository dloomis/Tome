@preconcurrency import AVFoundation
import FluidAudio
@testable import Tome

/// Scriptable ASRBackend for state-machine tests — no real models, no network.
/// `prepare` behavior is driven by `PrepareScript`; `transcribe` can be made to
/// hang until released, to exercise the coordinator's deferred-unload path.
final actor FakeBackend: @preconcurrency ASRBackend {
    enum PrepareScript: Sendable {
        /// Emit .downloading ticks then .loading, then succeed.
        case succeed(ticks: Int)
        /// Emit one .downloading tick then throw.
        case fail(message: String)
        /// Suspend until cancelled (or forever). Respects Task cancellation
        /// only when `cooperative` — an uncooperative hang models SDK calls
        /// that never check cancellation.
        case hang(cooperative: Bool)
        /// Suspend until `releasePrepare()` is called, then succeed —
        /// models a download that completes AFTER the user re-selected
        /// (late-success generation-guard tests).
        case succeedWhenReleased
        /// Suspend until `releasePrepare()` is called, then throw.
        case failWhenReleased(message: String)
    }

    struct FakeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated let model: TranscriberModel
    private let script: PrepareScript
    private(set) var prepareCalls = 0
    private(set) var unloadCalls = 0
    private var prepareGate: CheckedContinuation<Void, Never>?
    private var transcribeGate: CheckedContinuation<Void, Never>?
    private(set) var transcribesStarted = 0
    private(set) var transcribesFinished = 0
    /// When true, transcribe suspends until releaseTranscribe().
    var hangTranscribe = false

    init(model: TranscriberModel, script: PrepareScript = .succeed(ticks: 2)) {
        self.model = model
        self.script = script
    }

    static func isInstalled() -> Bool { false }

    func setHangTranscribe(_ hang: Bool) { hangTranscribe = hang }

    func releasePrepare() {
        prepareGate?.resume()
        prepareGate = nil
    }

    func releaseTranscribe() {
        transcribeGate?.resume()
        transcribeGate = nil
    }

    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws {
        prepareCalls += 1
        switch script {
        case .succeed(let ticks):
            for i in 0..<ticks {
                try Task.checkCancellation()
                onEvent(.downloading(progress: Double(i) / Double(max(ticks, 1))))
                await Task.yield()
            }
            onEvent(.loading)
        case .fail(let message):
            onEvent(.downloading(progress: 0))
            throw FakeError(message: message)
        case .hang(let cooperative):
            onEvent(.downloading(progress: nil))
            if cooperative {
                // Sleep respects cancellation.
                try await Task.sleep(for: .seconds(3600))
            } else {
                await withCheckedContinuation { prepareGate = $0 }
            }
        case .succeedWhenReleased:
            onEvent(.downloading(progress: nil))
            await withCheckedContinuation { prepareGate = $0 }
            onEvent(.loading)
        case .failWhenReleased(let message):
            onEvent(.downloading(progress: nil))
            await withCheckedContinuation { prepareGate = $0 }
            throw FakeError(message: message)
        }
    }

    func transcribe(samples: [Float], language: Language) async throws -> ASRResult {
        transcribesStarted += 1
        if hangTranscribe {
            await withCheckedContinuation { transcribeGate = $0 }
        }
        transcribesFinished += 1
        return ASRResult(
            text: "fake:\(model.rawValue)", confidence: 1.0,
            duration: Double(samples.count) / 16_000.0, processingTime: 0.001
        )
    }

    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult {
        try await transcribe(samples: [], language: language)
    }

    func unload() async {
        unloadCalls += 1
    }
}
