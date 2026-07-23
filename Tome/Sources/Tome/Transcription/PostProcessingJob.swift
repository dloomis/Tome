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
        // Payload-less: the discarded transcript path points at a just-deleted
        // file; the outcome (which callers do read) carries it for logging.
        case discarded
        case failed(PostProcessingError)
        case cancelled
    }

    /// The two terminal results of a successful `run()`. Failures are thrown, not
    /// returned. A discard is neither success nor failure: nothing was written, so
    /// the queue publishes it on its own channel (`lastDiscard`) and the UI must not
    /// show a "Saved" banner or an open-file action.
    enum JobOutcome: Sendable {
        case saved(URL)
        /// The transcript path that was removed, plus the measured session length.
        case discarded(path: URL, durationSeconds: Int)
    }

    nonisolated let id: String
    private(set) var phase: Phase = .queued
    private(set) var progress: Double = 0

    /// Mutable so the finalizer can update `transcript.speakersDetected` as diarization
    /// replaces "Them" with specific speaker labels.
    var handle: SessionHandle

    let clusterThreshold: Float
    let numberOfSpeakers: Int

    /// Max gap (seconds) that still merges consecutive same-speaker diarized segments
    /// into one block. See `AppSettings.diarizationMergeGapSeconds`.
    let mergeGapSeconds: Double

    /// When set, the combined session audio is exported as `.m4a` into this folder
    /// after the transcript is finalized. Nil = retention off.
    let retention: RecordingRetentionConfig?

    /// When true, write a per-speaker voiceprint sidecar (`*.voiceprints.json`) next to
    /// the finalized transcript. Call captures only — needs a diarized system stream.
    let exportVoiceprints: Bool

    /// When set, a session that ran for ≤ this many seconds is discarded — its live
    /// transcript and every capture file are deleted and nothing reaches the output
    /// folders. Nil = feature off (or the session isn't eligible). The caller
    /// (`ContentView.stopSession`) applies the "call captures only" policy by passing
    /// this only for call captures with `AppSettings.discardShortMeetings` enabled.
    let discardIfShorterThanOrEqual: TimeInterval?

    init(handle: SessionHandle, clusterThreshold: Float, numberOfSpeakers: Int, mergeGapSeconds: Double = 1.5, retention: RecordingRetentionConfig? = nil, exportVoiceprints: Bool = false, discardIfShorterThanOrEqual: TimeInterval? = nil) {
        self.id = handle.id
        self.handle = handle
        self.clusterThreshold = clusterThreshold
        self.numberOfSpeakers = numberOfSpeakers
        self.mergeGapSeconds = mergeGapSeconds
        self.retention = retention
        self.exportVoiceprints = exportVoiceprints
        self.discardIfShorterThanOrEqual = discardIfShorterThanOrEqual
    }

    /// Run the full pipeline. The main-actor boundary between steps is where
    /// observers (UI) see phase transitions. Each `await` hops off main for the
    /// underlying compute.
    @discardableResult
    func run(using asr: ASRCoordinator) async throws(PostProcessingError) -> JobOutcome {
        if Task.isCancelled {
            phase = .cancelled
            throw .cancelled
        }

        // 1. Diarize + re-transcribe. Call captures diarize the system ("them") WAV and
        //    keep the live mic track as "You". Mic-only sessions (voice memos / in-person
        //    meetings) diarize the mic WAV itself — every speaker, including the recording
        //    user, comes from the diarizer, so labels start at 1 and the live "You" lines
        //    are replaced wholesale.
        diagLog("[JOB \(id)] starting run, wavBufferPath=\(handle.wavBufferPath?.path ?? "nil"), micWavPath=\(handle.micWavPath?.path ?? "nil"), sessionType=\(handle.sessionType)")
        if handle.wavWriteErrorCount > 0 {
            diagLog("[JOB \(id)] WARN: system-audio WAV had \(handle.wavWriteErrorCount) write errors during capture — diarization input may be incomplete")
        }

        // External-rename fallback: the user's vault pipeline (WhisperCal) can
        // retitle the live note before this job runs — every rewrite step below
        // would then fail markdownReadFailed and the diarized rebuild would be
        // lost (field-observed 2026-07-10). Follow the rename via the preserved
        // `source_file:` key; `relocated(to:)` keeps the curated name by clearing
        // the rename inputs, and the sidecar is re-pointed so a crash after this
        // still leaves a recoverable pairing.
        if let renamed = TranscriptFinalizer.relocateRenamedNote(from: handle.transcript.filePath) {
            diagLog("[JOB \(id)] transcript renamed externally — following to \(renamed.lastPathComponent)")
            handle.transcript = handle.transcript.relocated(to: renamed)
            if let wavPath = handle.wavBufferPath ?? handle.micWavPath {
                SessionSidecar.updateTranscriptPath(forWAV: wavPath, to: renamed)
            }
        }

        // External-deletion fallback (incident 2026-07-23): deleting the meeting
        // note in the vault pipeline removes the live transcript entirely, so
        // there is nothing to relocate — and every rewrite step below would fail
        // markdownReadFailed, aborting the job with the WAVs stranded. Rebuild a
        // live-format note from the session JSONL and continue as an unlinked
        // meeting. A rebuild failure isn't fatal here: the job then fails
        // downstream exactly as before, preserving the capture files.
        if !FileManager.default.fileExists(atPath: handle.transcript.filePath.path),
           let jsonlURL = handle.jsonlURL,
           FileManager.default.fileExists(atPath: jsonlURL.path) {
            do {
                try TranscriptRebuilder.rebuildLiveNote(
                    jsonlURL: jsonlURL,
                    at: handle.transcript.filePath,
                    sessionType: handle.sessionType,
                    sourceApp: handle.sourceApp,
                    sessionGuid: handle.sessionGuid,
                    sessionStart: handle.transcript.sessionStartTime
                )
                diagLogError("[JOB \(id)] transcript was deleted externally — rebuilt from \(jsonlURL.lastPathComponent), continuing as unlinked note")
            } catch {
                diagLogError("[JOB \(id)] transcript missing and JSONL rebuild failed: \(error) — job will fail downstream, capture files preserved")
            }
        }

        // Short-recording discard: a session at/under the user's threshold is almost
        // certainly a canceled or mis-started meeting. Drop it here — before any
        // expensive diarization — so nothing lands in the output folders. The
        // sessionType check backstops the caller's call-captures-only policy: a
        // voice memo is deliberate however short, and must never be discarded.
        if let limit = discardIfShorterThanOrEqual, handle.sessionType == .callCapture {
            let duration = handle.transcript.sessionEndTime.timeIntervalSince(handle.transcript.sessionStartTime)
            if duration <= limit {
                return discardShortSession(durationSeconds: Int(duration.rounded()))
            }
        }

        // Per-session-type diarization plan.
        let diarBufferURL: URL?
        let speakerBase: Int
        let preserveYou: Bool
        let voiceprintSource: String
        let voiceprintIncludesYou: Bool
        switch handle.sessionType {
        case .callCapture:
            diarBufferURL = handle.wavBufferPath
            speakerBase = 2
            preserveYou = true
            voiceprintSource = "system"
            voiceprintIncludesYou = false
        case .voiceMemo:
            diarBufferURL = handle.micWavPath
            speakerBase = 1
            preserveYou = false
            voiceprintSource = "mic"
            voiceprintIncludesYou = true
        }

        var diarOutput: DiarizationOutput?
        var didRebuildSpeakers = false
        if let bufferURL = diarBufferURL {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: bufferURL.path)[.size] as? Int) ?? -1
            diagLog("[JOB \(id)] buffer file size=\(fileSize) bytes, exists=\(FileManager.default.fileExists(atPath: bufferURL.path))")
            phase = .diarizing
            diagLog("[JOB \(id)] diarizing \(bufferURL.lastPathComponent)")
            let diar = await TranscriptionEngine.runDiarization(
                bufferURL: bufferURL,
                clusterThreshold: clusterThreshold,
                numberOfSpeakers: numberOfSpeakers
            )
            diarOutput = diar
            diagLog("[JOB \(id)] diarization returned: \(diar == nil ? "nil" : "\(diar!.segments.count) segments")")

            if Task.isCancelled {
                // Leave the WAVs + sidecar in place: a cancelled job is an
                // *unfinished* session, and the launch-time orphan scan is its
                // recovery path. Deleting here would turn cancellation into
                // permanent loss of the only diarization source.
                phase = .cancelled
                throw .cancelled
            }

            // Mic-only collapse: a solo memo (≤1 detected speaker) keeps its live "You"
            // transcript untouched — no re-transcription, no relabel, no voiceprint. Only a
            // multi-speaker in-person session is rebuilt into Speaker 1..N. Call captures
            // always rebuild when diarization produced segments (existing behavior).
            let segments = diar?.segments ?? []
            let distinctSpeakers = Set(segments.map(\.speakerId)).count
            let shouldRebuild = handle.sessionType == .callCapture
                ? !segments.isEmpty
                : distinctSpeakers >= 2
            if handle.sessionType == .voiceMemo && !shouldRebuild {
                diagLog("[JOB \(id)] mic diarization found \(distinctSpeakers) speaker(s) — keeping live 'You' transcript")
            }

            if shouldRebuild, !segments.isEmpty {
                phase = .reTranscribing
                diagLog("[JOB \(id)] re-transcribing \(segments.count) diarized segments (speakerBase=\(speakerBase))")
                let results = await TranscriptionEngine.reTranscribe(
                    asrCoordinator: asr,
                    bufferURL: bufferURL,
                    segments: segments,
                    speakerNumberBase: speakerBase,
                    mergeGapSeconds: mergeGapSeconds
                )

                if Task.isCancelled {
                    // As above: keep the capture files so the orphan scan can recover.
                    phase = .cancelled
                    throw .cancelled
                }

                do {
                    if let results, !results.isEmpty {
                        try TranscriptFinalizer.rebuildFromDiarizedSegments(
                            snapshot: &handle.transcript,
                            diarizedSegments: results,
                            preserveYou: preserveYou
                        )
                        didRebuildSpeakers = true
                    } else if handle.sessionType == .callCapture {
                        // Call-capture fallback: relabel "Them" by overlap when re-transcription
                        // produced nothing. Mic-only sessions have no "Them" lines to relabel,
                        // so they keep the live "You" transcript instead.
                        diagLog("[JOB \(id)] re-transcription empty, falling back to relabel")
                        try TranscriptFinalizer.rewriteWithDiarization(
                            snapshot: &handle.transcript,
                            segments: segments
                        )
                        didRebuildSpeakers = true
                    } else {
                        diagLog("[JOB \(id)] mic re-transcription empty — keeping live 'You' transcript")
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
            // Mic-only sessions have no system WAV — their preserved audio is the
            // mic track, so log whichever capture file recovery will lean on.
            if let bufferURL = handle.wavBufferPath ?? handle.micWavPath {
                handleDurableWriteFailure(bufferURL: bufferURL, error: error)
            }
            phase = .failed(error)
            throw error
        }

        // Finalization may have renamed the note; the crash-recovery sidecar still
        // points at the old path. Refresh it so a crash/quit between here and
        // cleanup leaves an orphan that auto-recovery can actually pair up.
        // Mic-only sessions carry their sidecar on the mic WAV.
        if savedPath != handle.transcript.filePath,
           let wavPath = handle.wavBufferPath ?? handle.micWavPath {
            SessionSidecar.updateTranscriptPath(forWAV: wavPath, to: savedPath)
        }

        // 2b. Emit per-speaker voiceprints next to the finalized transcript (opt-in).
        //     Keyed by the same "Speaker N" labels as the body so a downstream consumer
        //     can bind a centroid to the name the user confirms during speaker tagging.
        if exportVoiceprints {
            // Skip when the body wasn't rebuilt into Speaker labels (e.g. a solo voice memo
            // kept as "You"): the sidecar keys must match the transcript's speaker labels,
            // and `startingAt` must equal the base the body rewrite used.
            if didRebuildSpeakers,
               let diar = diarOutput,
               let sidecar = VoiceprintSidecar.build(from: diar, source: voiceprintSource, includesYou: voiceprintIncludesYou, startingAt: speakerBase, sessionGuid: handle.sessionGuid) {
                let sidecarURL = VoiceprintSidecar.sidecarURL(forTranscript: savedPath)
                do {
                    try VoiceprintSidecar.write(sidecar, to: sidecarURL)
                    TranscriptFinalizer.setVoiceprintsLink(filePath: savedPath, sidecarFilename: sidecarURL.lastPathComponent)
                    diagLog("[JOB \(id)] wrote \(sidecar.speakers.count) voiceprints (source=\(voiceprintSource)) → \(sidecarURL.lastPathComponent)")
                } catch {
                    diagLog("[JOB \(id)] voiceprint sidecar write failed (non-fatal): \(error)")
                }
            } else {
                // Opt-in was on but there's nothing to emit (no rebuilt speakers, no system
                // speech, too short, or a backend without centroids) — say so, don't go silent.
                diagLog("[JOB \(id)] voiceprints enabled but none emitted (no rebuilt speakers / centroids for this session)")
            }
        }

        // 3. Retain the combined recording before deleting the source WAVs. The
        //    transcript is already saved, so a retention failure doesn't fail the
        //    job — but it MUST block cleanup: the user explicitly asked to keep this
        //    audio, and the source WAVs are the only copy until the .m4a exists.
        //    Preserved WAVs surface through the next-launch orphan scan.
        var sourceAudioDisposition = SourceAudioDisposition.deletable
        if let retention {
            switch await exportRetainedRecording(to: retention.folder, transcriptPath: savedPath) {
            case .exported(let audioURL):
                TranscriptFinalizer.setRecordingLink(filePath: savedPath, audioFilename: audioURL.lastPathComponent)
            case .noSource:
                break  // nothing to retain, nothing lost by cleanup
            case .failed:
                sourceAudioDisposition = .preserve
                diagLog("[JOB \(id)] retention export failed — keeping capture WAVs in the sessions dir so the audio isn't lost (orphan scan will offer them next launch)")
            }
        }

        if sourceAudioDisposition == .deletable {
            cleanupCaptureFiles()
        }

        phase = .complete(savedPath)
        diagLog("[JOB \(id)] complete → \(savedPath.lastPathComponent)")
        return .saved(savedPath)
    }

    /// Discard a session that ran at or under the configured short-recording threshold.
    /// Removes the live transcript from the vault and every capture file, so nothing
    /// reaches the output folders — no transcript, no retained `.m4a`, no voiceprints
    /// (the latter two never ran; this returns before diarization). Cheap by design.
    private func discardShortSession(durationSeconds: Int) -> JobOutcome {
        let path = handle.transcript.filePath
        diagLog("[JOB \(id)] discarding short session (\(durationSeconds)s ≤ threshold) — removing \(path.lastPathComponent) + capture files")
        try? FileManager.default.removeItem(at: path)
        // A discarded session keeps nothing: delete every capture file including this
        // session's own rotations (retention is moot when the whole session is dropped).
        cleanupCaptureFiles(discarding: true)
        phase = .discarded
        return .discarded(path: path, durationSeconds: durationSeconds)
    }

    /// Whether the source capture WAVs may be deleted at the end of the job.
    /// `.preserve` means a retention export the user asked for didn't land — the
    /// WAVs are then the only copy of the audio and must survive the job.
    private enum SourceAudioDisposition { case deletable, preserve }

    /// Outcome of a retention export, distinguishing "nothing to export" (cleanup
    /// is safe) from "export failed" (cleanup would destroy the only audio).
    enum RetentionOutcome { case exported(URL), noSource, failed }

    /// Combine the session's mic + system WAVs into one `.m4a` in `folder`, named to
    /// match the transcript stem (with a numeric suffix on collision). Voice memos
    /// export the mic track only.
    private func exportRetainedRecording(to folder: URL, transcriptPath: URL) async -> RetentionOutcome {
        let micArg: (url: URL, firstSample: Date)? = pair(handle.micWavPath, handle.micFirstSampleTime)
        let systemArg: (url: URL, firstSample: Date)? = handle.sessionType == .callCapture
            ? pair(handle.wavBufferPath, handle.systemFirstSampleTime)
            : nil
        guard micArg != nil || systemArg != nil else {
            diagLog("[JOB \(id)] retention: no source audio to combine, skipping")
            return .noSource
        }

        let sessionStart = handle.transcript.sessionStartTime
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            diagLog("[JOB \(id)] retention: could not create folder: \(error)")
            return .failed
        }
        let outputURL = uniqueURL(in: folder, stem: transcriptPath.deletingPathExtension().lastPathComponent, ext: "m4a")

        // Offline render is CPU-heavy and synchronous — run it off the main actor so
        // the UI stays responsive (mirrors how diarize / re-transcribe hop off-main).
        let produced = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try RecordingMixer.produce(mic: micArg, system: systemArg, sessionStart: sessionStart, outputURL: outputURL)
                diagLog("[JOB] retention: wrote \(outputURL.lastPathComponent)")
                return true
            } catch {
                diagLog("[JOB] retention: combine failed: \(error)")
                return false
            }
        }.value

        return produced ? .exported(outputURL) : .failed
    }

    /// Delete both transient capture WAVs (and the system sidecar) for this session,
    /// plus any rotated `.pre-…` segments `WAVStreamWriter` set aside during the
    /// session (e.g. a mid-session mic device swap). Runs ONLY on the verified
    /// success path: every failure/cancellation path leaves the files in place for
    /// the launch-time orphan scan — they are the only recovery source.
    private func cleanupCaptureFiles(discarding: Bool = false) {
        // A stale failure marker from an earlier failed run of this session id is
        // now contradicted by this verified success — remove it so tooling doesn't
        // flag a session that actually finalized.
        if let dir = handle.captureDirectory {
            JobFailureMarker.deleteIfExists(forSessionId: id, in: dir)
        }
        if let bufferURL = handle.wavBufferPath {
            SystemAudioCapture.cleanupBufferFile(bufferURL)
        }
        if let micURL = handle.micWavPath {
            try? FileManager.default.removeItem(at: micURL)
            // Mic-only sessions carry their crash-recovery sidecar on the mic WAV.
            SessionSidecar.deleteIfExists(forWAV: micURL)
        }
        // Rotated segments share the session-id stem: `<sid>.pre-<ts>.wav` /
        // `<sid>.pre-<ts>.mic.wav`, always next to the capture WAVs. Two
        // protections apply:
        //  • A rotation stamped BEFORE this session started belongs to a PRIOR
        //    session that failed to finalize (rotation preserved its audio when
        //    this session claimed the path) — this session's success says
        //    nothing about it. Never delete it here.
        //  • With retention ON, this session's own rotations hold pre-swap audio
        //    the mixer did NOT fold into the exported .m4a — deleting them would
        //    silently drop audio the user asked to keep. (With retention off the
        //    session's audio is discarded by design, rotations included.)
        if let dir = (handle.wavBufferPath ?? handle.micWavPath)?.deletingLastPathComponent(),
           let siblings = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let sessionStartMs = UInt64(max(0, handle.transcript.sessionStartTime.timeIntervalSince1970) * 1000)
            for url in siblings {
                guard let ts = Self.rotationTimestampMs(fromName: url.lastPathComponent, sessionId: id) else { continue }
                if ts < sessionStartMs {
                    diagLog("[JOB \(id)] keeping prior session's rotated segment \(url.lastPathComponent)")
                } else if retention != nil && !discarding {
                    diagLog("[JOB \(id)] keeping unmixed same-session rotation \(url.lastPathComponent) (retention is on; not in the exported audio)")
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Parse the epoch-millisecond stamp out of `<sessionId>.pre-<ts>[.mic].wav`.
    /// Nil for names that aren't this session's rotations.
    private static func rotationTimestampMs(fromName name: String, sessionId: String) -> UInt64? {
        let prefix = "\(sessionId).pre-"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix(while: \.isNumber)
        return digits.isEmpty ? nil : UInt64(digits)
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
