@preconcurrency import AVFoundation
import FluidAudio

/// Offline re-transcriber: takes diarization segments and the system audio WAV,
/// extracts each segment's audio, and runs Parakeet on it individually via the
/// shared `ASRCoordinator` so it properly serializes with live streaming.
struct SegmentReTranscriber: Sendable {
    let asrCoordinator: ASRCoordinator
    let fileURL: URL
    let segments: [DiarizedSegment]
    /// First speaker number for labels: 2 for call capture (system stream; "You" is the
    /// implicit Speaker 1), 1 for mic-only in-person diarization (every speaker, including
    /// the recording user, comes from the diarizer).
    let speakerNumberBase: Int
    /// Max gap (seconds) between two consecutive same-speaker segments that still merges
    /// them into one block/re-transcription span. See `AppSettings.diarizationMergeGapSeconds`.
    let mergeGapSeconds: Double

    func run() async -> [ReTranscribedSegment]? {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            let totalFrames = AVAudioFrameCount(audioFile.length)

            let speakerMap = speakerLabels(from: segments.map(\.speakerId), startingAt: speakerNumberBase)

            // Merge consecutive segments from the same speaker (gap ≤ mergeGapSeconds)
            var merged: [DiarizedSegment] = []
            for seg in segments {
                if let last = merged.last, last.speakerId == seg.speakerId,
                   seg.startTime - last.endTime <= Float(mergeGapSeconds) {
                    merged[merged.count - 1] = DiarizedSegment(
                        speakerId: last.speakerId,
                        startTime: last.startTime,
                        endTime: seg.endTime
                    )
                } else {
                    merged.append(seg)
                }
            }

            var output: [ReTranscribedSegment] = []

            let minSamples = Int(sampleRate * 1.5) // 1.5s to clear Parakeet's 1s minimum after resampling

            for seg in merged {
                var startFrame = AVAudioFramePosition(Double(seg.startTime) * sampleRate)
                var endFrame = min(AVAudioFramePosition(Double(seg.endTime) * sampleRate), AVAudioFramePosition(totalFrames))
                var frameCount = Int(endFrame - startFrame)

                // Pad short segments to meet Parakeet's minimum
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
                    let result = try await asrCoordinator.transcribe(buffer: buffer, source: .system)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let label = speakerMap[seg.speakerId] ?? "Speaker \(speakerNumberBase)"
                    output.append(ReTranscribedSegment(speaker: label, text: text, startTime: seg.startTime))
                } catch {
                    // Visible holes in the final transcript beat silent drops — the user can see
                    // which segment failed and re-record. "[transcription failed]" is the agreed
                    // placeholder convention; downstream rebuilders treat it as opaque text.
                    diagLog("[RETRANSCRIBE] Segment \(seg.startTime)-\(seg.endTime) failed: \(error.localizedDescription)")
                    let label = speakerMap[seg.speakerId] ?? "Speaker \(speakerNumberBase)"
                    output.append(ReTranscribedSegment(speaker: label, text: "[transcription failed]", startTime: seg.startTime))
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

/// A speaker/time triple produced by pyannote diarization.
struct DiarizedSegment: Sendable {
    let speakerId: String
    let startTime: Float
    let endTime: Float
}

/// Full diarization output: per-speaker segments plus an optional acoustic centroid
/// per raw speaker id ("SPEAKER_n"). Each centroid is the mean of that speaker's window
/// embeddings in SpeakerKit's raw embedder space (un-normalized); `VoiceprintSidecar`
/// L2-normalizes it before writing. Surfaced for downstream voiceprint enrollment. The
/// `centroids` map is empty when the diarizer produced no embeddings.
struct DiarizationOutput: Sendable {
    let segments: [DiarizedSegment]
    let centroids: [String: [Float]]
}

/// A segment after re-transcription with a speaker label.
struct ReTranscribedSegment: Sendable {
    let speaker: String
    let text: String
    let startTime: Float
}
