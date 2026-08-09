@preconcurrency import AVFoundation
import Foundation
import os

/// Turns an audio file into the thing live capture produces: an
/// `AsyncStream<AVAudioPCMBuffer>` of ~0.5 s mono float32 chunks at the file's
/// native sample rate, which `StreamingTranscriber` then consumes exactly as it
/// consumes `MicCapture`'s tap.
///
/// **The stream is pull-based, and that is the whole point.** It is built with
/// `AsyncStream(unfolding:)`, so a chunk is read from disk only when the
/// consumer asks for the next element — the ASR pipeline paces the reads and a
/// two-hour 48 kHz file never exists in memory. The natural-looking
/// `AsyncStream { continuation in Task { … } }` shape compiles, passes every
/// other behavioural test, and silently buffers hundreds of megabytes because
/// its producer task runs to completion regardless of how slowly the consumer
/// drains it. `diskReadCount` exists so that difference is *asserted* rather
/// than assumed (see `FileAudioReaderTests`).
///
/// Two deliberate non-transformations:
/// - **No resampling.** `StreamingTranscriber.extractSamples` already converts
///   any input format to 16 kHz mono Float32, for live buffers and these alike.
/// - **Downmix to mono, though.** That is channel normalization, not
///   resampling, and it is what `MicCapture`'s tap already does before yielding:
///   the 16 kHz fast path in `extractSamples` reads channel 0 only, so a stereo
///   file whose voice sits on channel 1 would otherwise transcribe as silence.
///
/// Reads are synchronous on the consumer's thread. That is safe by construction
/// here: the import stage copies the source into the sessions directory before
/// reading it (§5.5), so this is always a local file, and one chunk is a few
/// tens of kilobytes against an ASR pipeline that costs orders of magnitude more.
final class FileAudioReader: @unchecked Sendable {

    /// Cumulative read position, for the import status row.
    struct Progress: Sendable, Equatable {
        let framesConsumed: AVAudioFramePosition
        let totalFrames: AVAudioFramePosition

        /// 0…1, clamped. Exact — unlike live capture, the length is known up front.
        var fraction: Double {
            guard totalFrames > 0 else { return 0 }
            return min(1, Double(framesConsumed) / Double(totalFrames))
        }
    }

    /// ~0.5 s per chunk: small enough that cancelling an import responds
    /// promptly, large enough that a long file isn't thousands of reads.
    static let defaultChunkDuration: TimeInterval = 0.5

    let url: URL
    /// Format the yielded buffers carry: mono float32 non-interleaved at the
    /// file's native rate — the same shape `MicCapture` yields.
    let outputFormat: AVAudioFormat
    let totalFrames: AVAudioFramePosition
    let durationSeconds: Double
    let chunkFrames: AVAudioFrameCount

    private let file: AVAudioFile
    /// `file.processingFormat` — what `read(into:)` requires the destination
    /// buffer to be. Always float32 non-interleaved; channel count is the file's.
    private let readFormat: AVAudioFormat

    private struct Counters: Sendable {
        var framesConsumed: AVAudioFramePosition = 0
        var diskReads: Int = 0
        var readError: String?
        var reachedEnd: Bool = false
    }
    private let counters = OSAllocatedUnfairLock<Counters>(initialState: Counters())

    /// Frames handed to the consumer so far on the current stream.
    var framesConsumed: AVAudioFramePosition { counters.withLock { $0.framesConsumed } }
    /// Number of `AVAudioFile.read` calls performed. The laziness seam: after
    /// consuming *k* chunks this must be exactly *k*.
    var diskReadCount: Int { counters.withLock { $0.diskReads } }
    /// Non-nil when a read failed mid-file — the stream ends early and the
    /// import stage treats it as a decode/read failure (§8) rather than EOF.
    var readError: String? { counters.withLock { $0.readError } }
    /// True once every frame has been delivered.
    var reachedEnd: Bool { counters.withLock { $0.reachedEnd } }

    var progress: Progress {
        Progress(framesConsumed: framesConsumed, totalFrames: totalFrames)
    }

    /// Open `url` for streaming. Throws `ImportError.notReadable` for anything
    /// `AVAudioFile` refuses or that decodes to a degenerate/empty format —
    /// the same decode gate `ImportSupport.inspectAudioFile` applies, so a
    /// validated file never fails here for a new reason.
    init(url: URL, chunkDuration: TimeInterval = FileAudioReader.defaultChunkDuration) throws {
        let filename = url.lastPathComponent
        guard let file = try? AVAudioFile(forReading: url) else {
            throw ImportError.notReadable(filename: filename)
        }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate > 0,
              format.channelCount >= 1,
              file.length > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        else {
            throw ImportError.notReadable(filename: filename)
        }

        self.url = url
        self.file = file
        self.readFormat = format
        self.outputFormat = mono
        self.totalFrames = file.length
        self.durationSeconds = Double(file.length) / format.sampleRate
        let requested = chunkDuration > 0 ? chunkDuration : Self.defaultChunkDuration
        self.chunkFrames = max(1, AVAudioFrameCount((requested * format.sampleRate).rounded()))

        diagLog("[IMPORT-READ] opened \(filename): frames=\(file.length) sr=\(format.sampleRate) ch=\(format.channelCount) chunk=\(chunkFrames)")
    }

    /// A pull-based stream over the whole file. Rewinds to the start, so a
    /// reader can be re-streamed (a retried import) deterministically.
    ///
    /// - Parameter onProgress: fired once per delivered chunk, on the
    ///   consumer's thread, with the cumulative frame position.
    func buffers(onProgress: (@Sendable (Progress) -> Void)? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        rewind()
        // `unfolding:` — NOT the continuation-based initializer. See the type
        // comment: the continuation shape would read the entire file ahead of
        // the consumer.
        return AsyncStream(unfolding: { [self] in
            self.nextChunk(onProgress: onProgress)
        })
    }

    private func rewind() {
        file.framePosition = 0
        counters.withLock { $0 = Counters() }
    }

    /// One pull: at most one `read`, at most one buffer. Returns nil at EOF or
    /// on a read failure, which ends the stream.
    private func nextChunk(onProgress: (@Sendable (Progress) -> Void)?) -> AVAudioPCMBuffer? {
        let stopped = counters.withLock { $0.reachedEnd || $0.readError != nil }
        guard !stopped else { return nil }

        // Check the position before touching the disk rather than reading and
        // discovering a zero-frame result: it keeps `diskReadCount` equal to the
        // number of delivered chunks, which is what the laziness test asserts on.
        guard file.framePosition < totalFrames else {
            counters.withLock { $0.reachedEnd = true }
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames) else {
            counters.withLock { $0.readError = "could not allocate a \(chunkFrames)-frame buffer" }
            diagLogError("[IMPORT-READ] buffer allocation failed for \(url.lastPathComponent)")
            return nil
        }

        do {
            try file.read(into: buffer, frameCount: chunkFrames)
            counters.withLock { $0.diskReads += 1 }
        } catch {
            counters.withLock {
                $0.diskReads += 1
                $0.readError = error.localizedDescription
            }
            diagLogError("[IMPORT-READ] read failed at frame \(file.framePosition) of \(url.lastPathComponent): \(error)")
            return nil
        }

        guard buffer.frameLength > 0 else {
            counters.withLock { $0.reachedEnd = true }
            return nil
        }

        // Normalize to mono exactly as the mic tap does (pass-through for a
        // mono file — no copy).
        guard let mono = MicCapture.downmixToMono(buffer) else {
            counters.withLock { $0.readError = "unsupported sample layout" }
            diagLogError("[IMPORT-READ] could not downmix \(url.lastPathComponent) (ch=\(readFormat.channelCount))")
            return nil
        }

        let consumed = counters.withLock { state -> AVAudioFramePosition in
            state.framesConsumed += AVAudioFramePosition(buffer.frameLength)
            if state.framesConsumed >= self.totalFrames { state.reachedEnd = true }
            return state.framesConsumed
        }
        onProgress?(Progress(framesConsumed: consumed, totalFrames: totalFrames))
        return mono
    }
}
