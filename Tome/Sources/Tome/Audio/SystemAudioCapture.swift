@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    private let _stream = OSAllocatedUnfairLock<SCStream?>(uncheckedState: nil)
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _micContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _audioLevel = AudioLevel()

    var audioLevel: Float { _audioLevel.value }

    // Temp WAV for diarization. The instance tracks the currently-writing path so
    // SCStream callbacks can find it; external callers receive the URL via `CaptureStreams`
    // and own its lifetime (including cleanup) from that point forward.
    private let _bufferFilePath = OSAllocatedUnfairLock<URL?>(uncheckedState: nil)

    private let _audioFileWriter = OSAllocatedUnfairLock<WAVStreamWriter?>(uncheckedState: nil)
    private let _writeErrors = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    /// Count of `AVAudioFile.write(from:)` failures during the current capture.
    /// Read by the engine at stop time to seed `SessionHandle.wavWriteErrorCount`.
    var writeErrorCount: Int { _writeErrors.withLock { $0 } }

    /// Wall-clock time of the most recent sample buffer delivered by SCStream while
    /// capture is active. `nil` when not capturing. The engine watchdog reads this to
    /// detect when ScreenCaptureKit has silently paused (e.g., display sleep, app
    /// permission revocation) — SCStream does not call `didStopWithError` in those cases.
    private let _lastSampleTime = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)
    var lastSampleTime: Date? { _lastSampleTime.withLock { $0 } }

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
        let bufferURL: URL
    }

    /// Start capturing system audio. Pass a bundle ID to filter to a specific app.
    /// `recordingContext` is required for the crash-recovery sidecar; when nil
    /// (legacy / test paths), falls back to the old `$TMPDIR`-based unnamed WAV.
    func bufferStream(
        appBundleID: String? = nil,
        recordingContext: SessionRecordingContext? = nil
    ) async throws -> CaptureStreams {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Build content filter — per-app if possible, otherwise all system audio
        let filter: SCContentFilter
        if let bundleID = appBundleID,
           let matchedApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            diagLog("[SYS-FILTER] Per-app filter: \(bundleID)")
            filter = SCContentFilter(display: display, including: [matchedApp], exceptingWindows: [])
        } else {
            if let bundleID = appBundleID {
                diagLog("[SYS-FILTER] App \(bundleID) not found in shareable content, falling back to all system audio")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        // Set up audio buffer file. With a recordingContext we write to a stable
        // location in Application Support so the WAV survives temp-dir purges and
        // we can pair it back to the session via the sidecar after a crash.
        let bufferURL: URL
        if let ctx = recordingContext {
            let dir = try Self.sessionsDirectory()
            bufferURL = dir.appendingPathComponent("\(ctx.sessionId).wav")
            // Sidecar emitted before the first audio byte so a crash within the
            // first second still leaves an identifiable pair on disk.
            let sidecar = SessionSidecar(
                schema: SessionSidecar.currentSchema,
                sessionId: ctx.sessionId,
                transcriptPath: ctx.transcriptURL.path,
                startedAt: ctx.startedAt,
                sourceApp: ctx.sourceApp,
                sessionType: ctx.sessionType,
                sampleRate: 48000,
                channels: 1,
                bitsPerSample: 32,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            )
            do {
                try SessionSidecar.write(sidecar, to: SessionSidecar.sidecarURL(forWAV: bufferURL))
                diagLog("[SIDECAR] wrote \(SessionSidecar.sidecarURL(forWAV: bufferURL).lastPathComponent)")
            } catch {
                diagLog("[SIDECAR] write failed: \(error) — orphan recovery for this session won't auto-pair")
            }
        } else {
            bufferURL = FileManager.default.temporaryDirectory.appendingPathComponent("tome_sys_audio_\(UUID().uuidString).wav")
        }
        _bufferFilePath.withLock { $0 = bufferURL }
        _audioFileWriter.withLock { $0 = nil } // will be created on first audio callback
        _writeErrors.withLock { $0 = 0 }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000

        // Minimal video — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        let sysStream = AsyncStream<AVAudioPCMBuffer> { cont in
            self._sysContinuation.withLock { $0 = cont }
        }

        _stream.withLock { $0 = scStream }
        // Seed before startCapture so the watchdog grace period begins now, not on the
        // first sample — avoids a false stall while SCK is initializing.
        _lastSampleTime.withLock { $0 = Date() }
        try await scStream.startCapture()

        return CaptureStreams(systemAudio: sysStream, bufferURL: bufferURL)
    }

    func stop() async {
        try? await _stream.withLock { $0 }?.stopCapture()
        _stream.withLock { $0 = nil }
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
        // Explicit close: flushes the final header refresh + synchronize so the
        // WAV is durably finalized before the post-processing job starts reading it.
        _audioFileWriter.withLock { writer in
            writer?.close()
            writer = nil
        }
        _bufferFilePath.withLock { $0 = nil }  // capture no longer owns this URL
        _lastSampleTime.withLock { $0 = nil }
        _audioLevel.value = 0
    }

    /// Remove a buffered audio file and its sidecar. Stateless — the caller owns
    /// the URL returned by `bufferStream` and is responsible for calling this
    /// after post-processing completes.
    static func cleanupBufferFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        SessionSidecar.deleteIfExists(forWAV: url)
    }

    /// `~/Library/Application Support/Tome/sessions/` — the stable home for
    /// system-audio WAVs and their sidecars. Co-located with `SessionStore`'s
    /// JSONL crash files so a single directory contains everything we'd need to
    /// reconstruct a session post-mortem.
    static func sessionsDirectory() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CaptureError.noApplicationSupport
        }
        let dir = appSupport.appendingPathComponent("Tome/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - SCStreamOutput

    private let _sampleCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              var asbd = formatDesc.audioStreamBasicDescription else { return }

        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // Update audio level for visualizer
        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.value = min(rms * 25, 1.0)
        _lastSampleTime.withLock { $0 = Date() }

        // Diagnostic: log raw system audio levels periodically
        let count = _sampleCount.withLock { val -> Int in val += 1; return val }
        if count <= 5 || count % 200 == 0 {
            diagLog("[SYS-RAW] #\(count) frames=\(frameCount) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) rms=\(rms)")
        }

        // Buffer audio to disk for post-session diarization. WAVStreamWriter keeps
        // the RIFF / data chunk sizes fresh on every write so a crash leaves a
        // valid WAV — see WAVStreamWriter.swift for the rationale.
        let sampleRate = asbd.mSampleRate
        _audioFileWriter.withLock { writer in
            if writer == nil, let bufferPath = self._bufferFilePath.withLock({ $0 }) {
                do {
                    writer = try WAVStreamWriter(url: bufferPath, sampleRate: sampleRate)
                } catch {
                    diagLog("[SYS-WAV-FAIL] could not open writer at \(bufferPath.path): \(error)")
                    return
                }
            }
            if let w = writer {
                do {
                    try w.write(pcmBuffer)
                } catch {
                    let total = self._writeErrors.withLock { count -> Int in count += 1; return count }
                    if total == 1 || total % 100 == 0 {
                        diagLog("[SYS-WAV-FAIL] write #\(total) failed: \(error)")
                    }
                }
            }
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("SystemAudioCapture: stream stopped with error: \(error)")
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channelData[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(frameLength))
    }

    enum CaptureError: Error {
        case noDisplay
        case noApplicationSupport
    }
}
