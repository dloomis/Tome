import Foundation
import Observation

/// One unit of post-session work: diarize → re-transcribe → rebuild/rewrite transcript → finalize frontmatter.
/// Created at stop time by the main actor, enqueued on `PostProcessingQueue`, and runs
/// serially with any other jobs. The queue's consumer invokes `run(using:)` on the
/// main actor; every heavy operation inside yields via `await` so observation updates
/// and UI remain responsive while the actual compute happens on nonisolated executors.
@Observable
@MainActor
final class PostProcessingJob: Identifiable {
    enum Phase: Sendable {
        case queued
        case diarizing
        case reTranscribing
        case finalizing
        case complete(URL)
        case failed(PostProcessingError)
        case cancelled
    }

    nonisolated let id: String
    private(set) var phase: Phase = .queued
    private(set) var progress: Double = 0

    /// Mutable so the finalizer can update `transcript.speakersDetected` as diarization
    /// replaces "Them" with specific speaker labels.
    var handle: SessionHandle

    let clusterThreshold: Float
    let numberOfSpeakers: Int

    init(handle: SessionHandle, clusterThreshold: Float, numberOfSpeakers: Int) {
        self.id = handle.id
        self.handle = handle
        self.clusterThreshold = clusterThreshold
        self.numberOfSpeakers = numberOfSpeakers
    }

    /// Run the full pipeline. The main-actor boundary between steps is where
    /// observers (UI) see phase transitions. Each `await` hops off main for the
    /// underlying compute.
    @discardableResult
    func run(using asr: ASRCoordinator) async throws(PostProcessingError) -> URL {
        if Task.isCancelled {
            phase = .cancelled
            throw .cancelled
        }

        // 1. Diarize + re-transcribe when we have a system-audio buffer (call captures).
        diagLog("[JOB \(id)] starting run, wavBufferPath=\(handle.wavBufferPath?.path ?? "nil"), sessionType=\(handle.sessionType)")
        if let bufferURL = handle.wavBufferPath {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: bufferURL.path)[.size] as? Int) ?? -1
            diagLog("[JOB \(id)] buffer file size=\(fileSize) bytes, exists=\(FileManager.default.fileExists(atPath: bufferURL.path))")
            phase = .diarizing
            diagLog("[JOB \(id)] diarizing \(bufferURL.lastPathComponent)")
            let segments = await TranscriptionEngine.runDiarization(
                bufferURL: bufferURL,
                clusterThreshold: clusterThreshold,
                numberOfSpeakers: numberOfSpeakers
            )
            diagLog("[JOB \(id)] diarization returned: \(segments == nil ? "nil" : "\(segments!.count) segments")")

            if Task.isCancelled {
                SystemAudioCapture.cleanupBufferFile(bufferURL)
                phase = .cancelled
                throw .cancelled
            }

            if let segments, !segments.isEmpty {
                phase = .reTranscribing
                diagLog("[JOB \(id)] re-transcribing \(segments.count) diarized segments")
                let results = await TranscriptionEngine.reTranscribe(
                    asrCoordinator: asr,
                    bufferURL: bufferURL,
                    segments: segments
                )

                if Task.isCancelled {
                    SystemAudioCapture.cleanupBufferFile(bufferURL)
                    phase = .cancelled
                    throw .cancelled
                }

                if let results, !results.isEmpty {
                    TranscriptFinalizer.rebuildFromDiarizedSegments(
                        snapshot: &handle.transcript,
                        diarizedSegments: results
                    )
                } else {
                    diagLog("[JOB \(id)] re-transcription empty, falling back to relabel")
                    TranscriptFinalizer.rewriteWithDiarization(
                        snapshot: &handle.transcript,
                        segments: segments
                    )
                }
            }

            SystemAudioCapture.cleanupBufferFile(bufferURL)
        }

        // 2. Finalize frontmatter and rename the file as needed.
        phase = .finalizing
        guard let savedPath = TranscriptFinalizer.finalizeFrontmatter(snapshot: handle.transcript) else {
            let err = PostProcessingError.markdownWriteFailed("No transcript snapshot")
            phase = .failed(err)
            throw err
        }

        phase = .complete(savedPath)
        diagLog("[JOB \(id)] complete → \(savedPath.lastPathComponent)")
        return savedPath
    }
}
