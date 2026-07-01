@preconcurrency import AVFoundation
import Foundation

/// Crash-resilient WAV writer for float32 mono PCM. Maintains a valid RIFF +
/// `data` chunk size at all times so an abrupt termination (crash, SIGKILL,
/// power loss) leaves the file readable up to the last `synchronize()`
/// checkpoint.
///
/// Replaces `AVAudioFile(forWriting:)` in `SystemAudioCapture`. AVAudioFile only
/// finalizes the RIFF/data chunk size fields on `close()`; any crash mid-write
/// leaves the on-disk header claiming zero data bytes even though hundreds of
/// MB of samples are physically present — see the 2026-05-20 KSP incident for
/// the failure mode this writer prevents.
///
/// Throttles `synchronize()` to ~1 Hz so the SCStream callback (userInteractive
/// QoS, real-time-ish) isn't blocked on fsync more often than necessary.
/// Worst-case audio loss on crash is the bytes written since the last
/// synchronize — bounded by `syncInterval`.
///
/// Format choice: `WAVE_FORMAT_IEEE_FLOAT` (audio format = 3) with a simple
/// 44-byte header. AVAudioFile / WhisperKit's AudioProcessor read this layout
/// without issue. WAV's 4 GB file size limit means recordings beyond ~5.8 h at
/// 48 kHz mono float32 would overflow the size fields — acceptable for now;
/// meetings don't run that long and the alternative (RF64) isn't worth it.
final class WAVStreamWriter: @unchecked Sendable {
    enum OpenMode: Sendable {
        /// Create a fresh file, overwriting anything already at `url`.
        case create
        /// Reopen an existing file at `url` and continue appending after its
        /// current contents. The caller must pass the same `sampleRate`/
        /// `channels`/`bitsPerSample` the file was originally created with —
        /// this mode does not re-derive them from the on-disk header.
        case append
    }

    private let fileHandle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    private var dataBytes: UInt32 = 0
    private var lastSync = Date.distantPast
    private let syncInterval: TimeInterval = 1.0
    private var closed = false

    /// Open a WAV file at `url`. In `.create` mode (the default), overwrites any
    /// existing file and writes the 44-byte header with placeholder sizes; sizes
    /// are refreshed on every subsequent `write` so the file is always parseable.
    /// In `.append` mode, reopens an existing file and picks up `dataBytes` from
    /// its current size so header refreshes stay accurate.
    init(url: URL, sampleRate: Double, channels: UInt16 = 1, bitsPerSample: UInt16 = 32, mode: OpenMode = .create) throws {
        self.sampleRate = UInt32(sampleRate)
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        switch mode {
        case .create:
            let header = Self.buildHeader(
                sampleRate: self.sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample
            )

            // createFile + FileHandle(forUpdating:) — Data.write(to:) wouldn't leave
            // us a writable handle for the seek-and-update dance below.
            let created = FileManager.default.createFile(atPath: url.path, contents: header)
            guard created else {
                throw NSError(
                    domain: "WAVStreamWriter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create WAV file at \(url.path)"]
                )
            }
            let handle = try FileHandle(forUpdating: url)
            try handle.seekToEnd()
            self.fileHandle = handle
        case .append:
            let handle = try FileHandle(forUpdating: url)
            let endOffset = try handle.seekToEnd()
            self.dataBytes = endOffset > 44 ? UInt32(endOffset - 44) : 0
            self.fileHandle = handle
        }
    }

    /// Append a buffer's samples. Expects float32 non-interleaved single-channel
    /// (the format SCStream emits with our `SystemAudioCapture` config).
    /// Refreshes the header size fields on every call; synchronize is throttled.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !closed else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let byteCount = frameLength * MemoryLayout<Float>.size
        let data = Data(bytes: channelData[0], count: byteCount)
        try fileHandle.write(contentsOf: data)
        dataBytes &+= UInt32(byteCount)

        // Header bytes are tiny; rewriting them every buffer is microseconds.
        // What's expensive is `synchronize()` — we only call that at syncInterval.
        try refreshHeaderSizes()

        let now = Date()
        if now.timeIntervalSince(lastSync) >= syncInterval {
            try fileHandle.synchronize()
            lastSync = now
        }
    }

    /// Final header refresh + sync + close. Idempotent.
    func close() {
        guard !closed else { return }
        closed = true
        try? refreshHeaderSizes()
        try? fileHandle.synchronize()
        try? fileHandle.close()
    }

    /// Seek to the two size fields in the WAV header, update them with current
    /// `dataBytes`, then seek back to the previous offset (end of file).
    private func refreshHeaderSizes() throws {
        let currentPos = try fileHandle.offset()

        // RIFF chunk size at byte 4: payload size = 36 + dataBytes
        // (4 bytes "WAVE" + 24 bytes fmt chunk + 8 bytes data chunk header + samples).
        var riffSize = (UInt32(36) &+ dataBytes).littleEndian
        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Data(bytes: &riffSize, count: 4))

        // data chunk size at byte 40
        var dataSize = dataBytes.littleEndian
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: Data(bytes: &dataSize, count: 4))

        try fileHandle.seek(toOffset: currentPos)
    }

    /// Build the canonical 44-byte WAV header (RIFF/WAVE, fmt, data) with size
    /// fields set to zero — overwritten as samples are appended.
    private static func buildHeader(
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        var data = Data(capacity: 44)

        // RIFF chunk
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])              // "RIFF"
        appendLE(UInt32(36), to: &data)                                // chunk size placeholder
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])              // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])              // "fmt "
        appendLE(UInt32(16), to: &data)                                // fmt chunk size
        appendLE(UInt16(3), to: &data)                                 // WAVE_FORMAT_IEEE_FLOAT
        appendLE(channels, to: &data)
        appendLE(sampleRate, to: &data)
        let byteRate = sampleRate &* UInt32(channels) &* UInt32(bitsPerSample) / 8
        appendLE(byteRate, to: &data)
        let blockAlign = channels &* bitsPerSample / 8
        appendLE(blockAlign, to: &data)
        appendLE(bitsPerSample, to: &data)

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])              // "data"
        appendLE(UInt32(0), to: &data)                                 // data size placeholder

        return data
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
