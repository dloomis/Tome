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

    /// When set, the combined session audio is exported as `.m4a` into this folder
    /// after the transcript is finalized. Nil = retention off.
    let retention: RecordingRetentionConfig?

    init(handle: SessionHandle, clusterThreshold: Float, numberOfSpeakers: Int, retention: RecordingRetentionConfig? = nil) {
        self.id = handle.id
        self.handle = handle
        self.clusterThreshold = clusterThreshold
        self.numberOfSpeakers = numberOfSpeakers
        self.retention = retention
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
        if handle.wavWriteErrorCount > 0 {
            diagLog("[JOB \(id)] WARN: system-audio WAV had \(handle.wavWriteErrorCount) write errors during capture — diarization input may be incomplete")
        }
        if handle.sessionType == .callCapture, let bufferURL = handle.wavBufferPath {
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
                cleanupCaptureFiles()
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

                do {
                    if let results, !results.isEmpty {
                        try TranscriptFinalizer.rebuildFromDiarizedSegments(
                            snapshot: &handle.transcript,
                            diarizedSegments: results
                        )
                    } else {
                        diagLog("[JOB \(id)] re-transcription empty, falling back to relabel")
                        try TranscriptFinalizer.rewriteWithDiarization(
                            snapshot: &handle.transcript,
                            segments: segments
                        )
                    }
                } catch {
                    handleDurableWriteFailure(bufferURL: bufferURL, error: error)
                    phase = .failed(error)
                    throw error
                }
            }
        }

        // 2. Finalize frontmatter and rename the file as needed. Only after this
        //    succeeds do we delete the system-audio buffer — keeping the WAV around
        //    means a write failure here is recoverable rather than permanently lost.
        phase = .finalizing
        let savedPath: URL
        do {
            savedPath = try TranscriptFinalizer.finalizeFrontmatter(snapshot: handle.transcript)
        } catch {
            if let bufferURL = handle.wavBufferPath {
                handleDurableWriteFailure(bufferURL: bufferURL, error: error)
            }
            phase = .failed(error)
            throw error
        }

        // 3. Retain the combined recording before deleting the source WAVs. Failure
        //    here is non-fatal — the transcript is already saved.
        if let retention {
            await exportRetainedRecording(to: retention.folder, transcriptPath: savedPath)
        }

        cleanupCaptureFiles()

        phase = .complete(savedPath)
        diagLog("[JOB \(id)] complete → \(savedPath.lastPathComponent)")
        return savedPath
    }

    /// Combine the session's mic + system WAVs into one `.m4a` in `folder`, named to
    /// match the transcript stem (with a numeric suffix on collision). Voice memos
    /// export the mic track only.
    private func exportRetainedRecording(to folder: URL, transcriptPath: URL) async {
        let micArg: (url: URL, firstSample: Date)? = pair(handle.micWavPath, handle.micFirstSampleTime)
        let systemArg: (url: URL, firstSample: Date)? = handle.sessionType == .callCapture
            ? pair(handle.wavBufferPath, handle.systemFirstSampleTime)
            : nil
        guard micArg != nil || systemArg != nil else {
            diagLog("[JOB \(id)] retention: no source audio to combine, skipping")
            return
        }

        let sessionStart = handle.transcript.sessionStartTime
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            diagLog("[JOB \(id)] retention: could not create folder (non-fatal): \(error)")
            return
        }
        let outputURL = uniqueURL(in: folder, stem: transcriptPath.deletingPathExtension().lastPathComponent, ext: "m4a")

        // Offline render is CPU-heavy and synchronous — run it off the main actor so
        // the UI stays responsive (mirrors how diarize / re-transcribe hop off-main).
        await Task.detached(priority: .utility) {
            do {
                try RecordingMixer.produce(mic: micArg, system: systemArg, sessionStart: sessionStart, outputURL: outputURL)
                diagLog("[JOB] retention: wrote \(outputURL.lastPathComponent)")
            } catch {
                diagLog("[JOB] retention: combine failed (non-fatal): \(error)")
            }
        }.value
    }

    /// Delete both transient capture WAVs (and the system sidecar) for this session,
    /// regardless of session type or retention. Runs on the success and cancellation
    /// paths so neither file is orphaned.
    private func cleanupCaptureFiles() {
        if let bufferURL = handle.wavBufferPath {
            SystemAudioCapture.cleanupBufferFile(bufferURL)
        }
        if let micURL = handle.micWavPath {
            try? FileManager.default.removeItem(at: micURL)
        }
    }

    private func pair(_ url: URL?, _ date: Date?) -> (url: URL, firstSample: Date)? {
        guard let url, let date else { return nil }
        return (url, date)
    }

    private func uniqueURL(in folder: URL, stem: String, ext: String) -> URL {
        let first = folder.appendingPathComponent("\(stem).\(ext)")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Called when a TranscriptFinalizer write step throws. The WAV already lives
    /// in `~/Library/Application Support/Tome/sessions/` (see SystemAudioCapture)
    /// so it's durable as-is — no move needed. The launch-time `OrphanScanner`
    /// will pick it up next time Tome starts and offer to re-run diarization.
    private func handleDurableWriteFailure(bufferURL: URL, error: PostProcessingError) {
        diagLog("[JOB \(id)] durable write failed: \(error) — WAV preserved at \(bufferURL.path)")
    }
}
