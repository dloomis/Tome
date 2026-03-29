@preconcurrency import AVFoundation
import FluidAudio

/// Offline re-transcriber: takes diarization segments and the system audio WAV,
/// extracts each segment's audio, and runs Parakeet on it individually.
final class SegmentReTranscriber: @unchecked Sendable {
    private let asrManager: AsrManager
    private let fileURL: URL
    private let segments: [(speakerId: String, startTime: Float, endTime: Float)]

    init(asrManager: AsrManager, fileURL: URL, segments: [(speakerId: String, startTime: Float, endTime: Float)]) {
        self.asrManager = asrManager
        self.fileURL = fileURL
        self.segments = segments
    }

    func run() async -> [(speaker: String, text: String, startTime: Float)]? {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            let totalFrames = AVAudioFrameCount(audioFile.length)

            let speakerMap = speakerLabels(from: segments.map(\.speakerId))

            // Merge consecutive segments from the same speaker
            var merged: [(speakerId: String, startTime: Float, endTime: Float)] = []
            for seg in segments {
                if let last = merged.last, last.speakerId == seg.speakerId,
                   seg.startTime - last.endTime < 0.5 {
                    merged[merged.count - 1].endTime = seg.endTime
                } else {
                    merged.append(seg)
                }
            }

            var output: [(speaker: String, text: String, startTime: Float)] = []

            let minSamples = Int(sampleRate * 1.5) // 1.5 seconds to clear Parakeet's 1s minimum after resampling

            for seg in merged {
                var startFrame = AVAudioFramePosition(Double(seg.startTime) * sampleRate)
                var endFrame = min(AVAudioFramePosition(Double(seg.endTime) * sampleRate), AVAudioFramePosition(totalFrames))
                var frameCount = Int(endFrame - startFrame)

                // Pad short segments to meet Parakeet's 1-second minimum
                if frameCount < minSamples && frameCount > 0 {
                    let deficit = minSamples - frameCount
                    let padBefore = min(AVAudioFramePosition(deficit / 2), startFrame)
                    let padAfter = min(deficit - Int(padBefore), Int(AVAudioFramePosition(totalFrames) - endFrame))
                    startFrame -= padBefore
                    endFrame += AVAudioFramePosition(padAfter)
                    frameCount = Int(endFrame - startFrame)
                }

                guard frameCount > 0 else { continue }
                let avFrameCount = AVAudioFrameCount(frameCount)

                audioFile.framePosition = startFrame
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: avFrameCount) else { continue }
                do {
                    try audioFile.read(into: buffer, frameCount: avFrameCount)
                    let result = try await asrManager.transcribe(buffer, source: .system)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let label = speakerMap[seg.speakerId] ?? "Speaker 2"
                    output.append((speaker: label, text: text, startTime: seg.startTime))
                } catch {
                    diagLog("[RETRANSCRIBE] Segment \(seg.startTime)-\(seg.endTime) failed: \(error.localizedDescription)")
                    continue
                }
            }

            diagLog("[RETRANSCRIBE] Produced \(output.count) segments from \(merged.count) merged diarization segments")
            return output
        } catch {
            diagLog("[RETRANSCRIBE] FAILED: \(error.localizedDescription)")
            return nil
        }
    }
}
