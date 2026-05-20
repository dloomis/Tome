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
    @MainActor
    static func run(
        wavURL: URL,
        transcriptURL: URL,
        asr: ASRCoordinator,
        clusterThreshold: Float,
        numberOfSpeakers: Int
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
            speakersDetected: ["You", "Them"],
            sourceApp: "Recovered",
            sessionContext: "",            // suppresses context-based rename
            suggestedFilename: nil,        // suppresses explicit rename
            filenameDateFormat: "yyyy-MM-dd HH-mm-ss"
        )

        // Make sure FluidAudio's AsrManager is loaded before the re-transcribe step
        // calls into it. If the app just launched and no recording has run, the
        // models aren't loaded yet.
        try await asr.initialize()

        diagLog("[RECOVERY] diarizing \(wavURL.lastPathComponent), duration=\(Int(wav.durationSeconds))s, sessionStart=\(sessionStartTime)")
        guard let segments = await TranscriptionEngine.runDiarization(
            bufferURL: wavURL,
            clusterThreshold: clusterThreshold,
            numberOfSpeakers: numberOfSpeakers
        ), !segments.isEmpty else {
            throw RecoveryError.diarizationProducedNothing
        }

        diagLog("[RECOVERY] re-transcribing \(segments.count) segments")
        let results = await TranscriptionEngine.reTranscribe(
            asrCoordinator: asr,
            bufferURL: wavURL,
            segments: segments
        )

        do {
            if let results, !results.isEmpty {
                try TranscriptFinalizer.rebuildFromDiarizedSegments(
                    snapshot: &snapshot,
                    diarizedSegments: results
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
