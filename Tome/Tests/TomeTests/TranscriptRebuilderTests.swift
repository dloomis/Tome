import Foundation
import Testing
@testable import Tome

/// The JSONL rebuild is the last line of defense when the live note was deleted
/// externally (incident 2026-07-23). Its output must be indistinguishable from a
/// note the live logger wrote — the finalizer regexes and the diarization
/// interleave both anchor on that exact shape.
@Suite struct TranscriptRebuilderTests {

    private func writeJSONL(
        at url: URL,
        records: [(speaker: Speaker, text: String, offset: TimeInterval)],
        start: Date
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines = ""
        for r in records {
            let record = SessionRecord(speaker: r.speaker, text: r.text, timestamp: start.addingTimeInterval(r.offset))
            lines += String(decoding: try encoder.encode(record), as: UTF8.self) + "\n"
        }
        try Data(lines.utf8).write(to: url)
    }

    @Test func rebuiltNoteMatchesLiveFormatAndFinalizes() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        // Whole-second start: the JSONL round-trips timestamps through ISO-8601,
        // which drops fractional seconds — a fractional start would shift every
        // rebuilt offset by the fraction.
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded())
        let jsonl = dir.appendingPathComponent("session_test.jsonl")
        // Deliberately out of order — the rebuild must sort by timestamp.
        try writeJSONL(at: jsonl, records: [
            (.them, "second line", 12.0),
            (.you, "first line", 2.0),
        ], start: start)

        let noteURL = dir.appendingPathComponent("Rebuilt Call.md")
        try TranscriptRebuilder.rebuildLiveNote(
            jsonlURL: jsonl,
            at: noteURL,
            sessionType: .callCapture,
            sourceApp: "Teams",
            sessionGuid: "rebuild-guid",
            sessionStart: start
        )

        let content = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(content.contains("## Transcript"))
        #expect(content.contains("session_guid: \"rebuild-guid\""))
        #expect(content.contains("source_app: \"Teams\""))
        #expect(content.contains("**You** (2.000)\nfirst line"))
        #expect(content.contains("**Them** (12.000)\nsecond line"))
        #expect(content.range(of: "first line")!.lowerBound < content.range(of: "second line")!.lowerBound,
                "utterances must be sorted by timestamp")

        // The whole point: the normal finalize pipeline must run on the rebuild.
        var snapshot = TestSupport.snapshot(filePath: noteURL, start: start, end: start.addingTimeInterval(605))
        try TranscriptFinalizer.rebuildFromDiarizedSegments(
            snapshot: &snapshot,
            diarizedSegments: [ReTranscribedSegment(speaker: "Speaker 2", text: "diarized text", startTime: 12.5)],
            preserveYou: true
        )
        let finalized = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(finalized.contains("**You** (2.000)"), "live You lines interleave with diarized segments")
        #expect(finalized.contains("**Speaker 2**"))

        let saved = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snapshot)
        #expect(try String(contentsOf: saved, encoding: .utf8).contains("duration: \"10:05\""),
                "frontmatter finalization must patch the rebuilt note")
    }

    @Test func malformedLinesAreSkippedNotFatal() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let start = Date()
        let jsonl = dir.appendingPathComponent("s.jsonl")
        try writeJSONL(at: jsonl, records: [(.you, "good line", 1.0)], start: start)
        // A crash can truncate the tail mid-record.
        let handle = try FileHandle(forWritingTo: jsonl)
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("{\"speaker\":\"you\",\"tex".utf8))
        try handle.close()

        let noteURL = dir.appendingPathComponent("note.md")
        try TranscriptRebuilder.rebuildLiveNote(
            jsonlURL: jsonl, at: noteURL, sessionType: .voiceMemo,
            sourceApp: "Voice Memo", sessionGuid: "g", sessionStart: start
        )
        #expect(try String(contentsOf: noteURL, encoding: .utf8).contains("good line"))
    }

    @Test func refusesToClobberAnExistingNote() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let start = Date()
        let jsonl = dir.appendingPathComponent("s.jsonl")
        try writeJSONL(at: jsonl, records: [(.you, "x", 1.0)], start: start)
        let noteURL = dir.appendingPathComponent("existing.md")
        try Data("precious".utf8).write(to: noteURL)

        #expect(throws: TranscriptRebuilder.RebuildError.self) {
            try TranscriptRebuilder.rebuildLiveNote(
                jsonlURL: jsonl, at: noteURL, sessionType: .callCapture,
                sourceApp: "T", sessionGuid: "g", sessionStart: start
            )
        }
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == "precious")
    }

    @Test func emptyOrMissingJSONLThrows() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let empty = dir.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)

        #expect(throws: TranscriptRebuilder.RebuildError.self) {
            _ = try TranscriptRebuilder.readUtterances(fromJSONL: empty)
        }
        #expect(throws: TranscriptRebuilder.RebuildError.self) {
            _ = try TranscriptRebuilder.readUtterances(fromJSONL: dir.appendingPathComponent("missing.jsonl"))
        }
    }
}
