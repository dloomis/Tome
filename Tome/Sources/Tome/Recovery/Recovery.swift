@preconcurrency import AVFoundation
import Foundation

/// Manual recovery of an orphaned session: a transcript .md whose live capture
/// ended without diarization (typically because Tome crashed before the
/// `PostProcessingJob` could run). The system audio WAV is still sitting in
/// `$TMPDIR` (or `~/Library/Application Support/Tome/recovery/` if a previous
/// finalization failed). The user pairs the two through the `Recover from WAV…`
/// menu command and this flow re-runs the same diarize → re-transcribe →
/// rebuild-body pipeline that the normal stop path uses.
///
/// Does NOT reuse `PostProcessingJob` because the job assumes a fresh stop:
/// it computes duration from wall-clock-since-start (gives the wrong number for
/// a stale orphan), and it renames the file from suggestedFilename/context
/// (would clobber a user-curated filename). The pure-function pieces
/// (`runDiarization`, `reTranscribe`, `rebuildFromDiarizedSegments`) are
/// stateless and reused as-is.
enum Recovery {

    enum RecoveryError: LocalizedError {
        case wavUnreadable(URL, Error)
        case transcriptUnreadable(URL)
        case noFrontmatter
        case noStartTime
        case diarizationProducedNothing
        case bodyRewriteFailed(PostProcessingError)
        case modelNotReady

        var errorDescription: String? {
            switch self {
            case .wavUnreadable(let url, let err):
                return "Couldn't open WAV \(url.lastPathComponent): \(err.localizedDescription)"
            case .transcriptUnreadable(let url):
                return "Couldn't read transcript \(url.lastPathComponent)"
            case .noFrontmatter:
                return "Transcript has no YAML frontmatter"
            case .noStartTime:
                return "Couldn't parse a start time from the transcript frontmatter"
            case .diarizationProducedNothing:
                return "Diarization returned no segments — WAV may be silent or too short"
            case .bodyRewriteFailed(let err):
                return "Body rewrite failed: \(err)"
            case .modelNotReady:
                return "Transcription model not ready — check Settings ▸ Transcription"
            }
        }
    }

    struct WAVInfo: Sendable {
        let url: URL
        let durationSeconds: Double
        let modifiedAt: Date
        let sizeBytes: Int64
    }

    /// Read WAV duration and file metadata without loading samples into memory.
    static func inspectWAV(_ url: URL) throws -> WAVInfo {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw RecoveryError.wavUnreadable(url, error)
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return WAVInfo(url: url, durationSeconds: duration, modifiedAt: mtime, sizeBytes: size)
    }

    /// Run the recovery pipeline. Returns the transcript URL on success.
    /// Routes ASR through the shared coordinator so it serializes safely with any
    /// other ASR work in flight (caller is expected to gate against a live session).
    /// - Parameter preserveYou: true for call captures (the WAV is the system
    ///   stream; live "You" mic lines are kept and interleaved). False for
    ///   mic-only sessions (voice memos / in-person meetings) — there the WAV IS
    ///   the mic, so preserving "You" would duplicate every word the user said.
    @MainActor
    static func run(
        wavURL: URL,
        transcriptURL: URL,
        asr: ASRCoordinator,
        provisioner: ModelProvisioner,
        clusterThreshold: Float,
        numberOfSpeakers: Int,
        exportVoiceprints: Bool = false,
        preserveYou: Bool = true
    ) async throws -> URL {
        let wav = try inspectWAV(wavURL)

        // Best alignment: treat the WAV's last write as the recording's end, so
        // segment.startTime offsets reconstruct to real wall-clock timestamps.
        let sessionStartTime = wav.modifiedAt.addingTimeInterval(-wav.durationSeconds)

        // We don't actually parse much from the .md — the body is what we rewrite,
        // and frontmatter is preserved verbatim (the user's pipeline curates it
        // outside Tome). We just need *a* snapshot to feed the existing functions.
        var snapshot = TranscriptSessionSnapshot(
            filePath: transcriptURL,
            sessionStartTime: sessionStartTime,
            sessionEndTime: wav.modifiedAt,  // recording end ≈ WAV's last write
            speakersDetected: ["You", "Them"],
            sourceApp: "Recovered",
            sessionContext: "",            // suppresses context-based rename
            suggestedFilename: nil,        // suppresses explicit rename
            filenameDateFormat: "yyyy-MM-dd HH-mm-ss"
        )

        // Launch-time orphan recovery can race the provisioner's launch kick —
        // wait for it to settle (including an F2 fallback chain) instead of
        // triggering a second model load. If nothing is installed after
        // settling (fresh install, download failed), recovery can't run;
        // orphans stay on disk for a later launch or File ▸ Recover.
        await provisioner.awaitSettled()
        guard await asr.isReady else { throw RecoveryError.modelNotReady }

        diagLog("[RECOVERY] diarizing \(wavURL.lastPathComponent), duration=\(Int(wav.durationSeconds))s, sessionStart=\(sessionStartTime)")
        guard let diar = await TranscriptionEngine.runDiarization(
            bufferURL: wavURL,
            clusterThreshold: clusterThreshold,
            numberOfSpeakers: numberOfSpeakers
        ), !diar.segments.isEmpty else {
            throw RecoveryError.diarizationProducedNothing
        }
        let segments = diar.segments

        diagLog("[RECOVERY] re-transcribing \(segments.count) segments")
        // Mic-only sessions number speakers from 1 (the diarizer owns every
        // speaker, including the recording user); call captures reserve 1 for
        // the implicit "You" — mirrors PostProcessingJob's speakerBase.
        let results = await TranscriptionEngine.reTranscribe(
            asrCoordinator: asr,
            bufferURL: wavURL,
            segments: segments,
            speakerNumberBase: preserveYou ? 2 : 1
        )

        do {
            if let results, !results.isEmpty {
                try TranscriptFinalizer.rebuildFromDiarizedSegments(
                    snapshot: &snapshot,
                    diarizedSegments: results,
                    preserveYou: preserveYou
                )
            } else {
                try TranscriptFinalizer.rewriteWithDiarization(
                    snapshot: &snapshot,
                    segments: segments
                )
            }
        } catch {
            throw RecoveryError.bodyRewriteFailed(error)
        }

        // Surgical frontmatter + body-header update for fields the body rewrite
        // doesn't own. Updates `duration:` (frontmatter) and `**Duration:** MM:SS`
        // (body H2 line). Speaker count in the body header was already updated by
        // `rebuildFromDiarizedSegments`. Frontmatter `attendees:` is left alone
        // because users frequently maintain it via external tooling that
        // restructures it into a richer form Tome doesn't recognize.
        updateDurationFields(at: transcriptURL, durationSeconds: Int(wav.durationSeconds.rounded()))

        // Emit per-speaker voiceprints next to the recovered transcript (opt-in), mirroring
        // the normal stop path — the recovered WAV is the diarized system stream, and the
        // sidecar's "Speaker N" keys come from the same `speakerLabels` map the body rewrite
        // used. Best-effort: the transcript is already saved, so a failure here is non-fatal.
        if exportVoiceprints {
            if let sidecar = VoiceprintSidecar.build(from: diar, source: "system", includesYou: false) {
                let sidecarURL = VoiceprintSidecar.sidecarURL(forTranscript: transcriptURL)
                do {
                    try VoiceprintSidecar.write(sidecar, to: sidecarURL)
                    TranscriptFinalizer.setVoiceprintsLink(filePath: transcriptURL, sidecarFilename: sidecarURL.lastPathComponent)
                    diagLog("[RECOVERY] wrote \(sidecar.speakers.count) voiceprints → \(sidecarURL.lastPathComponent)")
                } catch {
                    diagLog("[RECOVERY] voiceprint sidecar write failed (non-fatal): \(error)")
                }
            } else {
                diagLog("[RECOVERY] voiceprints enabled but none emitted (no diarization centroids)")
            }
        }

        diagLog("[RECOVERY] complete: \(transcriptURL.lastPathComponent)")
        return transcriptURL
    }

    private static func updateDurationFields(at url: URL, durationSeconds: Int) {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let durStr = String(format: "%02d:%02d", durationSeconds / 60, durationSeconds % 60)

        // Frontmatter `duration:` — match quoted and unquoted forms because the
        // user's external pipeline strips the quotes Tome writes.
        if let range = content.range(of: #"duration:\s*"?\d{1,3}:\d{2}"?"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durStr)\"")
        }

        // Body H2 line `**Duration:** MM:SS | **Speakers:** N`. Speakers count was
        // already corrected by rebuildFromDiarizedSegments; we only touch Duration.
        if let range = content.range(of: #"\*\*Duration:\*\* \d{1,3}:\d{2}"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Duration:** \(durStr)")
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tome_recovery_tmp.md")
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            diagLog("[RECOVERY] duration field update failed: \(error)")
        }
    }
}
