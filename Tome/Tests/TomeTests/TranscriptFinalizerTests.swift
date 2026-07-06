import Foundation
import Testing
@testable import Tome

/// The finalizer's contract after the hardening: rewrite steps THROW when the
/// note can't be read (or lost its `## Transcript` anchor) — callers gate WAV
/// deletion on that. A silent no-op "success" here was the audit's worst bug.
@Suite struct TranscriptFinalizerTests {

    private let segs = [ReTranscribedSegment(speaker: "Speaker 2", text: "hello from them", startTime: 5.0)]

    @Test func rebuildThrowsWhenNoteUnreadable() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        var snap = TestSupport.snapshot(filePath: vault.appendingPathComponent("gone.md"))
        do {
            try TranscriptFinalizer.rebuildFromDiarizedSegments(snapshot: &snap, diarizedSegments: segs)
            Issue.record("must throw for a missing note")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
    }

    @Test func rebuildThrowsWhenTranscriptMarkerMissing() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let note = vault.appendingPathComponent("edited.md")
        try "# A note the user rewrote\n\nNo transcript section anymore.\n"
            .write(to: note, atomically: true, encoding: .utf8)

        var snap = TestSupport.snapshot(filePath: note)
        do {
            try TranscriptFinalizer.rebuildFromDiarizedSegments(snapshot: &snap, diarizedSegments: segs)
            Issue.record("must throw when '## Transcript' is gone")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
        // And the user's edited note must be untouched.
        #expect(try String(contentsOf: note, encoding: .utf8).contains("No transcript section anymore."))
    }

    @Test func rewriteWithDiarizationThrowsWhenNoteUnreadable() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        var snap = TestSupport.snapshot(filePath: vault.appendingPathComponent("gone.md"))
        do {
            try TranscriptFinalizer.rewriteWithDiarization(
                snapshot: &snap,
                segments: [DiarizedSegment(speakerId: "SPEAKER_0", startTime: 0, endTime: 3)]
            )
            Issue.record("must throw for a missing note")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
    }

    @Test func finalizeFrontmatterThrowsWhenNoteUnreadable() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let snap = TestSupport.snapshot(filePath: vault.appendingPathComponent("gone.md"))
        do {
            _ = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snap)
            Issue.record("must throw for a missing note")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
    }

    @Test func rebuildInterleavesDiarizedSegmentsWithPreservedYou() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        var snap = try await TestSupport.makeSessionNote(
            vault: vault,
            utterances: [("You", "my live line", 2.0)]
        )
        try TranscriptFinalizer.rebuildFromDiarizedSegments(snapshot: &snap, diarizedSegments: segs, preserveYou: true)

        let content = try String(contentsOf: snap.filePath, encoding: .utf8)
        // The You offset is measured from the logger's own session start, a few ms
        // before the fixture's reference time — match the value loosely.
        let youRange = try #require(content.range(of: #"\*\*You\*\* \(2\.\d{3}\)\nmy live line"#, options: .regularExpression))
        let themRange = try #require(content.range(of: "**Speaker 2** (5.000)\nhello from them"))
        #expect(youRange.lowerBound < themRange.lowerBound, "timeline must be offset-ordered")
        #expect(content.contains("**Speakers:** 2"))
        #expect(snap.speakersDetected == ["You", "Speaker 2"])
    }

    @Test func finalizeRenameNeverClobbersExistingNote() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        // The rename target already exists (e.g. last week's meeting).
        let occupied = vault.appendingPathComponent("Standup.md")
        try "precious prior meeting".write(to: occupied, atomically: true, encoding: .utf8)

        var snap = try await TestSupport.makeSessionNote(vault: vault)
        snap = TestSupport.snapshot(filePath: snap.filePath, suggestedFilename: "Standup")

        let saved = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snap)
        #expect(saved.lastPathComponent == "Standup-1.md")
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "precious prior meeting")
    }

    @Test func finalizeUpdatesDurationAndLeavesNoTempFiles() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let start = Date(timeIntervalSinceNow: -125)
        var snap = try await TestSupport.makeSessionNote(vault: vault)
        snap = TestSupport.snapshot(filePath: snap.filePath, start: start, end: start.addingTimeInterval(125))

        let saved = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snap)
        let content = try String(contentsOf: saved, encoding: .utf8)
        #expect(content.contains("duration: \"02:05\""))

        let strays = try FileManager.default.contentsOfDirectory(atPath: vault.path)
            .filter { $0.hasPrefix(".tome_") }
        #expect(strays.isEmpty, "unique-named temp files must be cleaned up, got \(strays)")
    }
}
