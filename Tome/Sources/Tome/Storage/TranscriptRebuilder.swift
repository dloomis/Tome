import Foundation

/// Rebuilds a live-format transcript note from a session's crash-recovery JSONL
/// (`~/Library/Application Support/Tome/sessions/<sessionId>.jsonl`).
///
/// This is the fallback for the incident-2026-07-23 failure mode: the live note
/// was deleted externally mid-session (a supported user action in the vault
/// pipeline), so at finalize time there is nothing to relocate — the note must
/// be reconstructed before diarization/finalization can land anywhere. The JSONL
/// is written and fsynced per utterance, which that incident proved is a
/// complete record of the live transcript body.
///
/// The rebuilt note uses `TranscriptLogger`'s own header + body renderers, so it
/// parses identically to a note the live logger wrote — `## Transcript` anchor,
/// `**You** (offset)` markers, patchable frontmatter and all.
enum TranscriptRebuilder {

    enum RebuildError: LocalizedError {
        case jsonlUnreadable(URL)
        case noUtterances(URL)
        case wouldClobber(URL)
        case writeFailed(URL, Error)

        var errorDescription: String? {
            switch self {
            case .jsonlUnreadable(let url):
                return "Couldn't read session journal \(url.lastPathComponent)"
            case .noUtterances(let url):
                return "Session journal \(url.lastPathComponent) has no utterances"
            case .wouldClobber(let url):
                return "A note already exists at \(url.lastPathComponent) — refusing to overwrite it"
            case .writeFailed(let url, let error):
                return "Couldn't write rebuilt transcript \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Decode a session JSONL into utterance records, sorted by timestamp.
    /// Tolerates individual malformed lines (a crash can truncate the tail);
    /// throws only when the file is unreadable or yields nothing at all.
    static func readUtterances(fromJSONL url: URL) throws -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url) else {
            throw RebuildError.jsonlUnreadable(url)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data($0.utf8)) }
        guard !records.isEmpty else {
            throw RebuildError.noUtterances(url)
        }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    /// Write a live-format note at `transcriptURL` from the session JSONL.
    /// Refuses to overwrite an existing file — callers only invoke this after
    /// establishing the note is gone, and racing an external tool that just
    /// recreated something at the path must not destroy it.
    @discardableResult
    static func rebuildLiveNote(
        jsonlURL: URL,
        at transcriptURL: URL,
        sessionType: SessionType,
        sourceApp: String,
        sessionGuid: String,
        sessionStart: Date
    ) throws -> URL {
        guard !FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw RebuildError.wouldClobber(transcriptURL)
        }
        let records = try readUtterances(fromJSONL: jsonlURL)

        var content = TranscriptLogger.documentHeader(
            sessionType: sessionType,
            sourceApp: sourceApp,
            filename: transcriptURL.lastPathComponent,
            sessionGuid: sessionGuid,
            startTime: sessionStart
        )
        let entries = records.map {
            (speaker: $0.speaker == .you ? "You" : "Them", text: $0.text, timestamp: $0.timestamp)
        }
        content += TranscriptLogger.renderUtterances(entries, start: sessionStart)

        do {
            try FileManager.default.createDirectory(
                at: transcriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw RebuildError.writeFailed(transcriptURL, error)
        }
        diagLog("[REBUILD] reconstructed \(transcriptURL.lastPathComponent) from \(jsonlURL.lastPathComponent) (\(records.count) utterances)")
        return transcriptURL
    }
}
