@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Tome

/// Scripted VAD — emits speech-boundary events by chunk index. No silero model,
/// so these tests exercise the transcriber's segmentation/flush logic hermetically.
private struct ScriptedVAD: VADStream {
    let events: [Int: VADEvent]
    var chunkIndex = 0

    mutating func process(_ chunk: [Float]) async throws -> VADEvent? {
        defer { chunkIndex += 1 }
        return events[chunkIndex]
    }
}

/// Thread-safe collector for finalized utterances (onFinal fires off-main).
private final class UtteranceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    func append(_ text: String) { lock.withLock { _texts.append(text) } }
    var texts: [String] { lock.withLock { _texts } }
}

@Suite struct StreamingTranscriberTests {

    /// 16kHz mono float32 — the transcriber's fast path (no resampling), the same
    /// shape ScreenCaptureKit delivers.
    private func makeBuffer(frames: Int) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = 0.5 * sinf(Float(i) * 0.1) }
        return buf
    }

    private func makeTranscriber(
        events: [Int: VADEvent],
        collector: UtteranceCollector
    ) async -> StreamingTranscriber {
        let coordinator = ASRCoordinator()
        await coordinator.install(backend: FakeBackend(model: .parakeetTDTv3), token: 1)
        return StreamingTranscriber(
            asrCoordinator: coordinator,
            vad: ScriptedVAD(events: events),
            speaker: .you,
            audioSource: .microphone,
            onPartial: { _ in },
            onFinal: { text, _ in collector.append(text) }
        )
    }

    /// THE stop-path regression (task-13 smoke test, sessions 09-09-15 and
    /// 09-14-06): speech still running when capture stops never gets a VAD
    /// speechEnd, so the pending samples must be flushed as a final utterance
    /// when the stream finishes. `TranscriptionEngine.stop()` relies on this —
    /// it finishes the capture streams and awaits this drain (instead of
    /// cancelling the task, which poisoned the flush's ASR call).
    @Test func finishingStreamFlushesPendingSpeechAsFinalUtterance() async throws {
        let collector = UtteranceCollector()
        let transcriber = await makeTranscriber(events: [0: .speechStart], collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        // ~2.3s of continuous speech in tap-sized buffers, then the capture
        // stops — buffers are queued BEFORE run() starts, proving a finished
        // stream still delivers everything already yielded.
        for _ in 0..<9 { continuation.yield(makeBuffer(frames: 4096)) }
        continuation.finish()

        let hadFatalError = await transcriber.run(stream: stream)
        #expect(hadFatalError == false)
        #expect(collector.texts == ["fake:parakeet-tdt-v3"])
    }

    /// A VAD speechEnd mid-stream commits its segment as before, and the
    /// re-started speech running at stream end is flushed as a second one.
    @Test func midStreamSpeechEndCommitsAndTailStillFlushes() async throws {
        let collector = UtteranceCollector()
        let transcriber = await makeTranscriber(
            events: [0: .speechStart, 3: .speechEnd, 4: .speechStart],
            collector: collector
        )

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        for _ in 0..<9 { continuation.yield(makeBuffer(frames: 4096)) }
        continuation.finish()

        let hadFatalError = await transcriber.run(stream: stream)
        #expect(hadFatalError == false)
        #expect(collector.texts.count == 2, "mid-stream segment AND stop-time tail must both commit: \(collector.texts)")
    }

    /// The sub-chunk remainder (< 4096 samples) sitting in the VAD buffer when
    /// the stream ends is speech the user spoke — it must be folded into the
    /// final segment. Here it's also what lifts the segment past the 8000-sample
    /// garbage threshold: 4096 + 4000 = 8096 samples commits only if folded.
    @Test func subChunkRemainderAtStreamEndIsIncludedInFinalSegment() async throws {
        let collector = UtteranceCollector()
        let transcriber = await makeTranscriber(events: [0: .speechStart], collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        continuation.yield(makeBuffer(frames: 4096))
        continuation.yield(makeBuffer(frames: 4000))
        continuation.finish()

        let hadFatalError = await transcriber.run(stream: stream)
        #expect(hadFatalError == false)
        #expect(collector.texts == ["fake:parakeet-tdt-v3"])
    }

    /// Sub-threshold trailing speech (Parakeet emits garbage below ~0.5s) is
    /// still dropped at stream end — the flush must not regress that guard.
    @Test func shortTrailingSpeechBelowGarbageThresholdIsDropped() async throws {
        let collector = UtteranceCollector()
        let transcriber = await makeTranscriber(events: [0: .speechStart], collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        continuation.yield(makeBuffer(frames: 4096))
        continuation.finish()

        let hadFatalError = await transcriber.run(stream: stream)
        #expect(hadFatalError == false)
        #expect(collector.texts.isEmpty)
    }

    /// Silence-only stream: nothing to flush, nothing committed.
    @Test func silenceOnlyStreamCommitsNothing() async throws {
        let collector = UtteranceCollector()
        let transcriber = await makeTranscriber(events: [:], collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        for _ in 0..<9 { continuation.yield(makeBuffer(frames: 4096)) }
        continuation.finish()

        let hadFatalError = await transcriber.run(stream: stream)
        #expect(hadFatalError == false)
        #expect(collector.texts.isEmpty)
    }
}
