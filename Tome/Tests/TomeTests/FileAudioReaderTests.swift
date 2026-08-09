import AVFoundation
import Foundation
import Testing
@testable import Tome

/// `FileAudioReader`'s contracts: every frame of the file reaches the consumer
/// exactly once, in live-capture-shaped buffers, and — the reason the reader is
/// built on `AsyncStream(unfolding:)` — *nothing* is read from disk until the
/// consumer asks for it. The eager `AsyncStream { continuation in … }` shape
/// passes every other test here while buffering a two-hour file into memory, so
/// laziness is pinned by a disk-read counter rather than by inspection.
@Suite struct FileAudioReaderTests {

    // MARK: - Fixtures

    /// Write a real 16-bit WAV with `AVAudioFile` (the file format the importer
    /// actually meets: integer samples on disk, float32 processing format on
    /// read). Returns the exact frame count written.
    @discardableResult
    private static func writeFixture(
        at url: URL,
        seconds: Double,
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1,
        silentChannels: Set<Int> = [],
        amplitude: Float = 0.8
    ) throws -> AVAudioFramePosition {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frames = AVAudioFrameCount(seconds * sampleRate)
        // A zero-length fixture is the "header only, no audio" case; AVAudioFile
        // writes the header on release, so simply skip the sample write.
        guard frames > 0 else { return 0 }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buf.floatChannelData![channel]
            let silent = silentChannels.contains(channel)
            for i in 0..<Int(frames) {
                data[i] = silent ? 0 : amplitude * sinf(Float(i) * 0.05)
            }
        }
        try file.write(from: buf)
        return AVAudioFramePosition(frames)
    }

    /// Drain a stream into (buffers, per-chunk frame counts).
    private static func drain(_ stream: AsyncStream<AVAudioPCMBuffer>) async -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        for await buffer in stream { out.append(buffer) }
        return out
    }

    // MARK: - Chunk math + full-file coverage

    @Test func chunkMathSplitsTheFileIntoWholeChunks() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("even.wav")
        let written = try Self.writeFixture(at: url, seconds: 2.5, sampleRate: 48_000)

        let reader = try FileAudioReader(url: url)
        #expect(reader.chunkFrames == 24_000, "0.5s at 48 kHz")
        #expect(reader.totalFrames == written)

        let buffers = await Self.drain(reader.buffers())
        #expect(buffers.count == 5)
        #expect(buffers.allSatisfy { $0.frameLength == 24_000 })
        #expect(buffers.reduce(0) { $0 + AVAudioFramePosition($1.frameLength) } == written,
                "every frame in the file must reach the consumer exactly once")
    }

    @Test func trailingPartialChunkIsShorterAndStillDelivered() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // 1.1s at 44.1 kHz = 48510 frames = 2 × 22050 + 4410.
        let url = dir.appendingPathComponent("odd.wav")
        let written = try Self.writeFixture(at: url, seconds: 1.1, sampleRate: 44_100)

        let reader = try FileAudioReader(url: url)
        #expect(reader.chunkFrames == 22_050)

        let buffers = await Self.drain(reader.buffers())
        #expect(buffers.count == 3)
        #expect(buffers.last?.frameLength == 4_410, "the tail must not be padded or dropped")
        #expect(buffers.reduce(0) { $0 + AVAudioFramePosition($1.frameLength) } == written)
        #expect(reader.framesConsumed == written)
        #expect(reader.readError == nil)
    }

    @Test func customChunkDurationChangesOnlyTheChunking() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("custom.wav")
        let written = try Self.writeFixture(at: url, seconds: 2.0, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url, chunkDuration: 0.25)
        #expect(reader.chunkFrames == 4_000)
        let buffers = await Self.drain(reader.buffers())
        #expect(buffers.count == 8)
        #expect(buffers.reduce(0) { $0 + AVAudioFramePosition($1.frameLength) } == written)
    }

    // MARK: - Pull-based laziness (the reason this class exists)

    @Test func constructingTheStreamReadsNothing() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("lazy-start.wav")
        try Self.writeFixture(at: url, seconds: 10, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url)
        #expect(reader.diskReadCount == 0)
        _ = reader.buffers()
        #expect(reader.diskReadCount == 0, "the stream must not prime itself with a read")
        #expect(reader.framesConsumed == 0)
    }

    @Test func readerNeverReadsPastTheLastConsumedChunk() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // 10s at 16 kHz = 160000 frames = 20 chunks of 8000. A producer-task
        // stream would have run to completion (20 reads) by the time the
        // consumer takes its third chunk; an unfolding stream reads exactly 3.
        let url = dir.appendingPathComponent("lazy.wav")
        let written = try Self.writeFixture(at: url, seconds: 10, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url)
        #expect(reader.chunkFrames == 8_000)
        #expect(reader.totalFrames == written)

        var iterator = reader.buffers().makeAsyncIterator()
        for _ in 0..<3 {
            #expect(await iterator.next() != nil)
        }
        // Give an eager producer every chance to run ahead before we assert.
        await Task.yield()

        #expect(reader.diskReadCount == 3, "no read-ahead past the last consumed chunk")
        #expect(reader.framesConsumed == 24_000)
        #expect(reader.framesConsumed < written, "the fixture must still have unread frames")

        for _ in 0..<2 {
            #expect(await iterator.next() != nil)
        }
        await Task.yield()
        #expect(reader.diskReadCount == 5, "each pull costs exactly one read")
        #expect(reader.framesConsumed == 40_000)
    }

    @Test func abandoningTheStreamLeavesTheRestOfTheFileUnread() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("abandoned.wav")
        try Self.writeFixture(at: url, seconds: 10, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url)
        do {
            var iterator = reader.buffers().makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
        }
        await Task.yield()
        #expect(reader.diskReadCount == 2,
                "a dropped iterator must not leave a producer draining the file")
    }

    @Test func fullDrainCostsExactlyOneReadPerChunk() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("drain.wav")
        try Self.writeFixture(at: url, seconds: 3, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url)
        let buffers = await Self.drain(reader.buffers())
        #expect(buffers.count == 6)
        #expect(reader.diskReadCount == 6, "no speculative read past EOF")
        #expect(reader.reachedEnd)
    }

    // MARK: - Progress reporting

    @Test func progressCallbackReportsCumulativeFramesEndingAtTheFileLength() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("progress.wav")
        let written = try Self.writeFixture(at: url, seconds: 1.1, sampleRate: 44_100)

        let collected = Collector()
        let reader = try FileAudioReader(url: url)
        _ = await Self.drain(reader.buffers { collected.record($0) })

        let reports = collected.reports
        #expect(reports.count == 3, "one report per delivered chunk")
        #expect(reports.map(\.framesConsumed) == [22_050, 44_100, written])
        #expect(reports.allSatisfy { $0.totalFrames == written })
        #expect(reports.last?.fraction == 1.0)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.framesConsumed < $1.framesConsumed },
                "progress must be monotonic")
    }

    @Test func progressIsReportedOnlyForFramesActuallyConsumed() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("progress-partial.wav")
        try Self.writeFixture(at: url, seconds: 10, sampleRate: 16_000)

        let collected = Collector()
        let reader = try FileAudioReader(url: url)
        var iterator = reader.buffers(onProgress: { collected.record($0) }).makeAsyncIterator()
        _ = await iterator.next()
        await Task.yield()

        #expect(collected.reports.count == 1)
        #expect(collected.reports.first?.framesConsumed == 8_000)
        #expect(abs((collected.reports.first?.fraction ?? 0) - 0.05) < 0.0001)
    }

    // MARK: - Buffer shape (parity with live mic capture)

    @Test func yieldsMonoFloat32BuffersAtTheFilesNativeRate() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("shape.wav")
        try Self.writeFixture(at: url, seconds: 2, sampleRate: 44_100, channels: 2)

        let reader = try FileAudioReader(url: url)
        #expect(reader.outputFormat.sampleRate == 44_100, "no resampling in the reader")
        #expect(reader.outputFormat.channelCount == 1)

        let buffers = await Self.drain(reader.buffers())
        let first = try #require(buffers.first)
        #expect(first.format.commonFormat == .pcmFormatFloat32)
        #expect(first.format.channelCount == 1)
        #expect(first.format.isInterleaved == false)
        #expect(first.format.sampleRate == 44_100)
    }

    @Test func multichannelInputIsDownmixedSoLaterChannelsSurvive() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // The mic landed on channel 1 (interface / aggregate recording). Channel-0
        // extraction would transcribe pure silence — MicCapture downmixes for the
        // same reason, and the import path must match.
        let url = dir.appendingPathComponent("stereo.wav")
        try Self.writeFixture(at: url, seconds: 2, sampleRate: 48_000, channels: 2, silentChannels: [0])

        let reader = try FileAudioReader(url: url)
        let buffers = await Self.drain(reader.buffers())
        let peak = buffers.reduce(Float(0)) { best, buffer in
            let data = buffer.floatChannelData![0]
            var local: Float = 0
            for i in 0..<Int(buffer.frameLength) { local = max(local, abs(data[i])) }
            return max(best, local)
        }
        #expect(peak > 0.1, "content on a non-zero channel must survive the downmix, got peak \(peak)")
    }

    // MARK: - Rejections and restart

    @Test func refusesFilesThatAreNotDecodableAudio() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let renamedJPEG = dir.appendingPathComponent("photo.wav")
        try Data(repeating: 0xFF, count: 4_096).write(to: renamedJPEG)
        #expect(throws: ImportError.notReadable(filename: "photo.wav")) {
            _ = try FileAudioReader(url: renamedJPEG)
        }

        let missing = dir.appendingPathComponent("nope.wav")
        #expect(throws: (any Error).self) { _ = try FileAudioReader(url: missing) }
    }

    @Test func refusesAnEmptyRecording() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("empty.wav")
        try Self.writeFixture(at: url, seconds: 0, sampleRate: 48_000)

        #expect(throws: ImportError.notReadable(filename: "empty.wav")) {
            _ = try FileAudioReader(url: url)
        }
    }

    @Test func aSecondStreamRereadsTheFileFromTheStart() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("restart.wav")
        let written = try Self.writeFixture(at: url, seconds: 1.5, sampleRate: 16_000)

        let reader = try FileAudioReader(url: url)
        var iterator = reader.buffers().makeAsyncIterator()
        _ = await iterator.next()

        let buffers = await Self.drain(reader.buffers())
        #expect(buffers.reduce(0) { $0 + AVAudioFramePosition($1.frameLength) } == written,
                "a fresh stream must rewind rather than resume mid-file")
        #expect(reader.diskReadCount == 3, "counters reset with the new stream")
    }
}

/// Progress sink usable from the reader's `@Sendable` callback.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileAudioReader.Progress] = []

    func record(_ progress: FileAudioReader.Progress) {
        lock.withLock { storage.append(progress) }
    }

    var reports: [FileAudioReader.Progress] {
        lock.withLock { storage }
    }
}
