@preconcurrency import AVFoundation
import FluidAudio
import os

// VAD + ASR pipeline
final class StreamingTranscriber: @unchecked Sendable {
    private let asrCoordinator: ASRCoordinator
    private var vad: any VADStream
    private let speaker: Speaker
    private let audioSource: AudioSource
    private let onPartial: @Sendable (String) -> Void
    /// Emits a finalized segment with the wall-clock time at which its speech
    /// *started* (not when ASR finished). The session's offset markers are derived
    /// downstream as `startTime − sessionStart`, so this must reflect the audio
    /// position, not the transcription latency.
    ///
    /// Awaited before `run()` continues — so when `run()` returns, every
    /// finalized utterance has been *delivered*, not merely scheduled. The
    /// stop path depends on this: it awaits `run()`'s task and then snapshots
    /// the transcript, which must already contain the tail utterance.
    private let onFinal: @Sendable (String, Date) async -> Void
    private let log = Logger(subsystem: tomeLogSubsystem, category: "StreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        asrCoordinator: ASRCoordinator,
        vad: any VADStream,
        speaker: Speaker,
        audioSource: AudioSource = .microphone,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String, Date) async -> Void
    ) {
        self.asrCoordinator = asrCoordinator
        self.vad = vad
        self.speaker = speaker
        self.audioSource = audioSource
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Flush speech for transcription every ~30 seconds (480,000 samples at 16kHz).
    /// Longer chunks give Parakeet-TDT more context for better accuracy.
    private static let flushInterval = 480_000

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    /// Returns `true` if the loop exited due to fatal (repeated) errors.
    ///
    /// Runs until `stream` FINISHES — the capture layer finishes its
    /// continuation on stop, buffered audio drains, and the in-progress
    /// utterance is flushed below. Do not cancel the task running this as the
    /// stop path: the ASR backends (FluidAudio, WhisperKit) check
    /// `Task.checkCancellation()` throughout inference, so a cancelled flush
    /// throws and the tail of the recording is silently dropped (task-13
    /// smoke-test finding, 2026-07-09).
    @discardableResult
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async -> Bool {
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false
        var bufferCount = 0
        var consecutiveErrors = 0

        // Audio clock for per-line offsets. `baseTime` is the wall-clock of the first
        // received sample (≈ capture start, the same anchor the recording mixer pads
        // each track to). `consumedSamples` counts 16kHz samples handed to the VAD, so
        // `segmentStartSample / 16000` is the audio position where a segment begins.
        var baseTime: Date?
        var consumedSamples = 0
        var segmentStartSample = 0

        func startDate(forSample sample: Int) -> Date {
            (baseTime ?? Date()).addingTimeInterval(Double(sample) / 16000.0)
        }

        outerLoop: for await buffer in stream {
            if baseTime == nil { baseTime = Date() }
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                diagLog("[\(speaker.rawValue)] buffer #\(bufferCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) interleaved=\(fmt.isInterleaved) common=\(fmt.commonFormat.rawValue)")
            }

            guard let samples = extractSamples(buffer) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                diagLog("[\(speaker.rawValue)] samples: count=\(samples.count) max=\(maxVal)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)
                consumedSamples += Self.vadChunkSize

                do {
                    let event = try await vad.process(chunk)
                    consecutiveErrors = 0

                    if let event {
                        switch event {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)
                            // Speech began somewhere in the chunk just consumed.
                            segmentStartSample = max(0, consumedSamples - Self.vadChunkSize)
                            diagLog("[\(self.speaker.rawValue)] speech start")

                        case .speechEnd:
                            isSpeaking = false
                            diagLog("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")
                            if speechSamples.count > 8000 {
                                let segment = speechSamples
                                let segStart = segmentStartSample
                                speechSamples.removeAll(keepingCapacity: true)
                                if await !transcribeSegment(segment, startTime: startDate(forSample: segStart)) {
                                    consecutiveErrors += 1
                                    if consecutiveErrors > 10 { break outerLoop }
                                } else {
                                    consecutiveErrors = 0
                                }
                            } else {
                                diagLog("[\(self.speaker.rawValue)] dropping short speech-end segment: samples=\(speechSamples.count) (<8000 ≈ 0.5s, Parakeet emits garbage below this threshold)")
                                speechSamples.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if isSpeaking {
                        speechSamples.append(contentsOf: chunk)

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            let segStart = segmentStartSample
                            speechSamples.removeAll(keepingCapacity: true)
                            // Next segment of this continuous run starts where this one ended.
                            segmentStartSample = consumedSamples
                            if await !transcribeSegment(segment, startTime: startDate(forSample: segStart)) {
                                consecutiveErrors += 1
                                if consecutiveErrors > 10 { break outerLoop }
                            } else {
                                consecutiveErrors = 0
                            }
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                    consecutiveErrors += 1
                    if consecutiveErrors > 10 { break outerLoop }
                }
            }
        }

        // Stream finished (capture stopped): flush the in-progress utterance.
        // Speech still running at stop never gets a VAD speechEnd, so without
        // this the tail of the recording is dropped. The sub-chunk remainder
        // in `vadBuffer` (< 256ms that never reached the VAD) is speech too —
        // fold it in rather than discarding it.
        if isSpeaking && !vadBuffer.isEmpty {
            speechSamples.append(contentsOf: vadBuffer)
        }
        if speechSamples.count > 8000 {
            diagLog("[\(self.speaker.rawValue)] flushing end-of-stream segment: samples=\(speechSamples.count)")
            _ = await transcribeSegment(speechSamples, startTime: startDate(forSample: segmentStartSample))
        } else if !speechSamples.isEmpty {
            diagLog("[\(self.speaker.rawValue)] dropping short end-of-stream remnant: samples=\(speechSamples.count) (<8000 ≈ 0.5s)")
        }

        return consecutiveErrors > 10
    }

    /// Returns `true` on success, `false` on ASR error.
    private func transcribeSegment(_ samples: [Float], startTime: Date) async -> Bool {
        do {
            let result = try await asrCoordinator.transcribe(samples: samples, source: audioSource)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            await onFinal(text, startTime)
            return true
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
            diagLog("[\(self.speaker.rawValue)] ASR error on \(samples.count)-sample segment: \(error.localizedDescription)")
            return false
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Fast path: already Float32 at 16kHz (common for system audio from ScreenCaptureKit)
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                // Mono — direct copy
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else {
                // Multi-channel — take first channel only
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }
        }

        // Slow path: need to resample via AVAudioConverter
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
