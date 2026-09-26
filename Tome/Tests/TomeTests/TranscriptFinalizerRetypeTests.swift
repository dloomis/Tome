import Foundation
import Testing
@testable import Tome

/// `TranscriptFinalizer.retypeAsVoiceMemo` — the single-button (auto-mode) path
/// that turns a provisionally-written call note into a voice memo at stop.
/// Destructive on the user's vault, so every test drives a real note produced by
/// the production `TranscriptLogger` and checks the on-disk result: which fields
/// changed, which bytes did NOT, where the note ended up, and that `source_file:`
/// never claims a name the file doesn't have.
@Suite struct TranscriptFinalizerRetypeTests {

    // MARK: - Fixtures

    /// Fixed start so filenames are deterministic and collisions can be staged.
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Vault {
        let root: URL
        var meetings: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
        var voice: URL { root.appendingPathComponent("Voice", isDirectory: true) }
    }

    private func makeVault() throws -> Vault {
        let root = try TestSupport.makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        return Vault(root: root)
    }

    private var datePrefix: String {
        FilenameSanitizer.formattedDate(start, format: "yyyy-MM-dd HH-mm-ss")
    }

    private func plan(
        _ vault: Vault,
        voiceFolder: URL? = nil,
        voiceLabel: String = "Voice Memo",
        callLabel: String = "Call Recording"
    ) -> RetypePlan {
        RetypePlan(
            voiceFolder: voiceFolder ?? vault.voice,
            voiceFilenameTypeLabel: voiceLabel,
            callFilenameTypeLabel: callLabel
        )
    }

    private static let defaultUtterances: [(speaker: String, text: String, offset: Double)] = [
        ("You", "hello there", 2.0),
        ("Them", "hi, can you hear me", 5.5),
        ("You", "yes, loud and clear", 9.25),
    ]

    /// A provisional call note, written exactly the way `.auto` writes one: the
    /// production logger, `.callCapture`, the call filename label, `source_app: "Call"`.
    private func makeCallNote(
        in dir: URL,
        callLabel: String? = "Call Recording",
        sessionType: SessionType = .callCapture,
        suggestedFilename: String? = nil,
        utterances: [(speaker: String, text: String, offset: Double)] = defaultUtterances
    ) async throws -> TranscriptSessionSnapshot {
        let logger = TranscriptLogger()
        try await logger.startSession(
            sourceApp: "Call",
            vaultPath: dir.path,
            sessionType: sessionType,
            sessionGuid: "retype-guid",
            suggestedFilename: suggestedFilename,
            filenameTypeLabel: callLabel,
            startedAt: start
        )
        for u in utterances {
            await logger.append(speaker: u.speaker, text: u.text, timestamp: start.addingTimeInterval(u.offset))
        }
        guard let snap = await logger.endSession(endTime: start.addingTimeInterval(90)) else {
            throw NSError(domain: "RetypeTests", code: 1)
        }
        return snap
    }

    /// Same snapshot with test-controlled rename inputs.
    private func with(
        _ s: TranscriptSessionSnapshot,
        context: String = "",
        suggestedFilename: String? = nil
    ) -> TranscriptSessionSnapshot {
        TranscriptSessionSnapshot(
            filePath: s.filePath,
            sessionGuid: s.sessionGuid,
            calendarEventId: s.calendarEventId,
            sessionStartTime: s.sessionStartTime,
            sessionEndTime: s.sessionEndTime,
            speakersDetected: s.speakersDetected,
            sourceApp: s.sourceApp,
            sessionContext: context,
            suggestedFilename: suggestedFilename,
            filenameDateFormat: s.filenameDateFormat
        )
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines strictly between the opening and closing `---` of the frontmatter.
    private func frontmatterLines(_ content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<end])
    }

    private func fmValue(_ content: String, _ key: String) -> String? {
        frontmatterLines(content).first { $0.hasPrefix("\(key):") }
    }

    /// Everything from `## Transcript` on — the utterance body.
    private func transcriptBody(_ content: String) -> Substring? {
        content.range(of: "## Transcript\n").map { content[$0.lowerBound...] }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func dirContents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Replace the first occurrence of `target` (must exist) in `s`.
    private func replacingFirst(_ target: String, with replacement: String, in s: String) throws -> String {
        let r = try #require(s.range(of: target), "fixture precondition: '\(target)' present")
        var out = s
        out.replaceSubrange(r, with: replacement)
        return out
    }

    /// The fixture note as step 3 of the retype must leave it: the typed fields
    /// and heading patched, every other byte — `source_file:` included — as read.
    private func retypedInPlace(_ before: String) throws -> String {
        var expected = before
        expected = try replacingFirst("type: meeting\n", with: "type: fleeting\n", in: expected)
        expected = try replacingFirst("source_app: \"Call\"\n", with: "source_app: \"Voice Memo\"\n", in: expected)
        expected = try replacingFirst("  - log/meeting\n", with: "  - log/voice\n", in: expected)
        expected = try replacingFirst("  - source/meeting\n", with: "  - source/voice\n", in: expected)
        expected = try replacingFirst("\n# Call Recording — ", with: "\n# Voice Memo — ", in: expected)
        return expected
    }

    private func expectReadFailed(_ body: () throws(PostProcessingError) -> Void) {
        do {
            try body()
            Issue.record("expected markdownReadFailed")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Field patches

    @Test func patchesEveryTypedFieldAndLeavesTheRestAlone() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let before = try read(snap.filePath)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        let after = try read(out.filePath)

        let fm = frontmatterLines(after)
        #expect(fm.contains("type: fleeting"))
        #expect(!fm.contains("type: meeting"))
        #expect(fm.contains("source_app: \"Voice Memo\""))
        #expect(fm.contains("  - log/voice"))
        #expect(fm.contains("  - source/voice"))
        #expect(fm.contains("  - status/inbox"))
        #expect(fm.contains("  - source/tome"))
        #expect(!after.contains("log/meeting"))
        #expect(!after.contains("source/meeting"))
        #expect(after.contains("\n# Voice Memo — "))
        #expect(!after.contains("# Call Recording"))

        // Untouched fields.
        for key in ["created", "time", "duration", "session_guid", "attendees", "context"] {
            #expect(fmValue(after, key) == fmValue(before, key), "\(key) must be untouched")
            #expect(fmValue(after, key) != nil)
        }
        #expect(fmValue(after, "session_guid") == "session_guid: \"retype-guid\"")
        // Body utterances byte-identical.
        #expect(try #require(transcriptBody(after)) == (try #require(transcriptBody(before))))
        #expect(!exists(snap.filePath), "the provisional call note must not be left behind")
    }

    @Test func outputIsByteIdenticalExceptThePatchedLines() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        // Transcript text that LOOKS like every patch target, plus the linked-note
        // keys — none of it may be touched, and none of it may block the move.
        let tricky: [(speaker: String, text: String, offset: Double)] = [
            ("You", "type: meeting", 1.0),
            ("Them", "# Call Recording — not a heading", 2.0),
            ("You", "  - log/meeting\n  - source/meeting\ntags: [log/meeting, source/meeting]", 3.0),
            ("Them", "source_app: \"Call\"\nsource_file: \"x.md\"\n---\nmeeting_note: \"[[Nope]]\"\npipeline_state: titled", 4.0),
            ("You", "ünïcödé — 🎙️ and trailing spaces   ", 5.0),
        ]
        let snap = try await makeCallNote(in: v.meetings, utterances: tricky)
        let before = try read(snap.filePath)
        let oldName = snap.filePath.lastPathComponent
        let newName = "\(datePrefix) Voice Memo.md"

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        let after = try read(out.filePath)

        // Patch targets in the frontmatter/header come first in the file, so a
        // first-occurrence replace hits exactly the lines the retype owns.
        var expected = before
        expected = try replacingFirst("type: meeting\n", with: "type: fleeting\n", in: expected)
        expected = try replacingFirst("source_app: \"Call\"\n", with: "source_app: \"Voice Memo\"\n", in: expected)
        expected = try replacingFirst("source_file: \"\(oldName)\"\n", with: "source_file: \"\(newName)\"\n", in: expected)
        expected = try replacingFirst("  - log/meeting\n", with: "  - log/voice\n", in: expected)
        expected = try replacingFirst("  - source/meeting\n", with: "  - source/voice\n", in: expected)
        expected = try replacingFirst("\n# Call Recording — ", with: "\n# Voice Memo — ", in: expected)

        #expect(after == expected)
        #expect(out.filePath.lastPathComponent == newName)
        #expect(out.filePath.deletingLastPathComponent().lastPathComponent == "Voice",
                "body text resembling linked-note keys must not pin the note in place")
    }

    // MARK: - Filename decision

    @Test func defaultCallNameIsRenamedToVoiceDefaultInVoiceFolder() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        #expect(snap.filePath.lastPathComponent == "\(datePrefix) Call Recording.md")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        let expectedName = "\(datePrefix) Voice Memo.md"
        #expect(out.filePath == v.voice.appendingPathComponent(expectedName))
        #expect(exists(out.filePath))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"\(expectedName)\"")
        #expect(dirContents(v.meetings).isEmpty)
    }

    @Test func testSupportDefaultNoteIsRecognized() async throws {
        // TestSupport.makeSessionNote passes no filename label → logger default
        // "Call Recording", start = now.
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await TestSupport.makeSessionNote(vault: v.meetings)
        let prefix = FilenameSanitizer.formattedDate(snap.sessionStartTime, format: snap.filenameDateFormat)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("\(prefix) Voice Memo.md"))
        #expect(frontmatterLines(try read(out.filePath)).contains("type: fleeting"))
    }

    @Test func collisionSuffixedDefaultNameIsRecognized() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        // Occupy the unsuffixed default name so the logger writes `-1`.
        let squatter = v.meetings.appendingPathComponent("\(datePrefix) Call Recording.md")
        try "someone else's note\n".write(to: squatter, atomically: true, encoding: .utf8)
        let snap = try await makeCallNote(in: v.meetings)
        #expect(snap.filePath.lastPathComponent == "\(datePrefix) Call Recording-1.md")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("\(datePrefix) Voice Memo.md"))
        #expect(try read(squatter) == "someone else's note\n", "neighbour note untouched")
    }

    @Test func customLabelsAreRecognizedAndApplied() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, callLabel: "Scheduled Meetings")
        #expect(snap.filePath.lastPathComponent == "\(datePrefix) Scheduled Meetings.md")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(
            snapshot: snap,
            plan: plan(v, voiceLabel: "Quick Notes", callLabel: "Scheduled Meetings")
        )

        let expectedName = "\(datePrefix) Quick Notes.md"
        #expect(out.filePath == v.voice.appendingPathComponent(expectedName))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"\(expectedName)\"")
    }

    @Test func emptyVoiceLabelGivesDateOnlyName() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceLabel: ""))

        #expect(out.filePath == v.voice.appendingPathComponent("\(datePrefix).md"))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"\(datePrefix).md\"")
    }

    @Test func emptyCallLabelDateOnlyNameIsRecognized() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, callLabel: "")
        #expect(snap.filePath.lastPathComponent == "\(datePrefix).md")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, callLabel: ""))

        #expect(out.filePath == v.voice.appendingPathComponent("\(datePrefix) Voice Memo.md"))
    }

    @Test func bothLabelsEmptyKeepsNameAndStillMoves() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, callLabel: "")
        let before = try read(snap.filePath)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceLabel: "", callLabel: ""))

        #expect(out.filePath == v.voice.appendingPathComponent("\(datePrefix).md"))
        #expect(fmValue(try read(out.filePath), "source_file") == fmValue(before, "source_file"))
    }

    @Test func mismatchedCallLabelIsNotMistakenForDefault() async throws {
        // A note named with a label that isn't the snapshotted call label is not
        // Tome's default name for this session — keep it.
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, callLabel: "Standup")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("\(datePrefix) Standup.md"))
    }

    @Test func contextRenamedSessionKeepsItsName() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        // Default-named on disk, but a context is set: finalizeFrontmatter will
        // rename it from the context later — retype must not pre-empt that.
        let base = try await makeCallNote(in: v.meetings)
        let snap = with(base, context: "Budget review with Alex")
        let before = try read(snap.filePath)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent(base.filePath.lastPathComponent))
        #expect(out.sessionContext == "Budget review with Alex", "withFilePath must keep the rename inputs")
        #expect(fmValue(try read(out.filePath), "source_file") == fmValue(before, "source_file"))
    }

    @Test func suggestedFilenameSessionKeepsItsName() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, suggestedFilename: "Weekly Sync")
        #expect(snap.filePath.lastPathComponent == "Weekly Sync.md")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("Weekly Sync.md"))
        #expect(out.suggestedFilename == "Weekly Sync")
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"Weekly Sync.md\"")
    }

    @Test func externallyRenamedNoteKeepsExternalNameAndSourceFileKey() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let base = try await makeCallNote(in: v.meetings)
        let renamed = v.meetings.appendingPathComponent("2026 Weekly Sync.md")
        try FileManager.default.moveItem(at: base.filePath, to: renamed)
        let snap = base.relocated(to: renamed)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("2026 Weekly Sync.md"))
        let after = try read(out.filePath)
        #expect(frontmatterLines(after).contains("type: fleeting"))
        // source_file still carries Tome's original name — the external
        // pipeline's correlation key must survive the move.
        #expect(fmValue(after, "source_file") == "source_file: \"\(base.filePath.lastPathComponent)\"")
    }

    // MARK: - YAML shapes

    @Test func whisperCalRoundTrippedYAMLStillPatches() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let oldName = snap.filePath.lastPathComponent
        var content = try read(snap.filePath)
        content = try replacingFirst("source_app: \"Call\"\n", with: "source_app: Call\n", in: content)
        content = try replacingFirst("source_file: \"\(oldName)\"\n", with: "source_file: \(oldName)\n", in: content)
        content = try replacingFirst(
            "tags:\n  - log/meeting\n  - status/inbox\n  - source/meeting\n  - source/tome\n",
            with: "tags: [log/meeting, status/inbox, source/meeting, source/tome]\n",
            in: content
        )
        content = try replacingFirst("duration: \"00:00\"\n", with: "duration: 00:00\n", in: content)
        try content.write(to: snap.filePath, atomically: true, encoding: .utf8)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        let after = try read(out.filePath)
        let fm = frontmatterLines(after)

        let newName = "\(datePrefix) Voice Memo.md"
        #expect(out.filePath == v.voice.appendingPathComponent(newName))
        #expect(fm.contains("type: fleeting"))
        #expect(fm.contains("source_app: \"Voice Memo\""))
        #expect(fm.contains("tags: [log/voice, status/inbox, source/voice, source/tome]"))
        #expect(fm.contains("source_file: \"\(newName)\""))
        #expect(fm.contains("duration: 00:00"), "round-tripped fields are left in their round-tripped form")
        #expect(after.contains("\n# Voice Memo — "))
    }

    @Test func quotedValuesAndQuotedTagItemsStillPatch() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        var content = try read(snap.filePath)
        content = try replacingFirst("type: meeting\n", with: "type: \"meeting\"\n", in: content)
        content = try replacingFirst("  - log/meeting\n", with: "  - \"log/meeting\"\n", in: content)
        content = try replacingFirst("  - source/meeting\n", with: "  - 'source/meeting'\n", in: content)
        try content.write(to: snap.filePath, atomically: true, encoding: .utf8)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        let fm = frontmatterLines(try read(out.filePath))

        #expect(fm.contains("type: fleeting"))
        #expect(fm.contains("  - \"log/voice\""))
        #expect(fm.contains("  - 'source/voice'"))
    }

    @Test func alreadyMemoShapedNoteIsIdempotentAndStillMoved() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        // JSONL-rebuild fallback shape: memo template, but Tome's default CALL name.
        let snap = try await makeCallNote(in: v.meetings, sessionType: .voiceMemo)
        #expect(snap.filePath.lastPathComponent == "\(datePrefix) Call Recording.md")
        let before = try read(snap.filePath)
        #expect(frontmatterLines(before).contains("type: fleeting"))

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        let after = try read(out.filePath)

        let newName = "\(datePrefix) Voice Memo.md"
        #expect(out.filePath == v.voice.appendingPathComponent(newName))
        var expected = try replacingFirst(
            "source_file: \"\(snap.filePath.lastPathComponent)\"\n",
            with: "source_file: \"\(newName)\"\n",
            in: before
        )
        // The fixture's source_app is "Call"; the retype always normalizes it.
        expected = try replacingFirst("source_app: \"Call\"\n", with: "source_app: \"Voice Memo\"\n", in: expected)
        #expect(after == expected, "only the name and source_app change on an already-memo note")

        // And a second retype of the result is a pure no-op.
        let again = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: out, plan: plan(v))
        #expect(again.filePath == out.filePath)
        #expect(try read(again.filePath) == after)
        #expect(dirContents(v.voice) == [newName])
    }

    // MARK: - Destination

    @Test func voiceFolderIsCreatedWhenMissing() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let deep = v.root.appendingPathComponent("Vault/Inbox/Voice", isDirectory: true)
        #expect(!exists(deep))

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceFolder: deep))

        #expect(out.filePath == deep.appendingPathComponent("\(datePrefix) Voice Memo.md"))
        #expect(exists(out.filePath))
    }

    @Test func collisionInVoiceFolderIsSuffixed() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        try FileManager.default.createDirectory(at: v.voice, withIntermediateDirectories: true)
        let occupant = v.voice.appendingPathComponent("\(datePrefix) Voice Memo.md")
        try "an earlier memo\n".write(to: occupant, atomically: true, encoding: .utf8)
        let snap = try await makeCallNote(in: v.meetings)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        let newName = "\(datePrefix) Voice Memo-1.md"
        #expect(out.filePath == v.voice.appendingPathComponent(newName))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"\(newName)\"")
        #expect(try read(occupant) == "an earlier memo\n", "never clobber an existing note")
    }

    @Test func collisionOnKeptNameIsSuffixedAndSourceFileFollows() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        try FileManager.default.createDirectory(at: v.voice, withIntermediateDirectories: true)
        let occupant = v.voice.appendingPathComponent("Weekly Sync.md")
        try "last week's\n".write(to: occupant, atomically: true, encoding: .utf8)
        let snap = try await makeCallNote(in: v.meetings, suggestedFilename: "Weekly Sync")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == v.voice.appendingPathComponent("Weekly Sync-1.md"))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"Weekly Sync-1.md\"")
        #expect(try read(occupant) == "last week's\n")
    }

    @Test func voiceFolderSameAsMeetingsFolderRenamesInPlace() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceFolder: v.meetings))

        #expect(out.filePath == v.meetings.appendingPathComponent("\(datePrefix) Voice Memo.md"))
        #expect(dirContents(v.meetings) == ["\(datePrefix) Voice Memo.md"])
        #expect(frontmatterLines(try read(out.filePath)).contains("type: fleeting"))
    }

    @Test func sameFolderWithKeptNameIsANoMoveRetype() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings, suggestedFilename: "Weekly Sync")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceFolder: v.meetings))

        #expect(out.filePath == snap.filePath)
        #expect(dirContents(v.meetings) == ["Weekly Sync.md"])
        #expect(frontmatterLines(try read(out.filePath)).contains("type: fleeting"))
    }

    // MARK: - Partial failure

    @Test func unwritableVoiceFolderLeavesRetypedMemoInMeetingsFolder() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let blocker = v.root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("sub", isDirectory: true)
        let snap = try await makeCallNote(in: v.meetings)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v, voiceFolder: unwritable))

        #expect(out.filePath.deletingLastPathComponent().standardizedFileURL == v.meetings.standardizedFileURL)
        #expect(exists(out.filePath))
        let after = try read(out.filePath)
        let fm = frontmatterLines(after)
        #expect(fm.contains("type: fleeting"))
        #expect(fm.contains("source_app: \"Voice Memo\""))
        #expect(fm.contains("  - log/voice"))
        #expect(after.contains("\n# Voice Memo — "))
        #expect(fmValue(after, "source_file") == "source_file: \"\(out.filePath.lastPathComponent)\"",
                "source_file must name the file it's actually in")
        #expect(dirContents(v.meetings) == [out.filePath.lastPathComponent], "exactly one note, no tmp debris")
    }

    @Test func unwritableVoiceFolderWithKeptNameLeavesPathUnchanged() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let blocker = v.root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let snap = try await makeCallNote(in: v.meetings, suggestedFilename: "Weekly Sync")

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(
            snapshot: snap,
            plan: plan(v, voiceFolder: blocker.appendingPathComponent("sub", isDirectory: true))
        )

        #expect(out.filePath == snap.filePath)
        let after = try read(out.filePath)
        #expect(frontmatterLines(after).contains("type: fleeting"))
        #expect(fmValue(after, "source_file") == "source_file: \"Weekly Sync.md\"")
    }

    @Test func failedCrossFolderMoveFallsBackToSameFolderRename() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let voice = v.voice

        // Moves INTO the voice folder fail (e.g. a sync provider refusing the
        // write after the folder was created); same-folder renames succeed.
        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v)) { from, to in
            if to.deletingLastPathComponent().lastPathComponent == voice.lastPathComponent {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }

        let newName = "\(datePrefix) Voice Memo.md"
        #expect(out.filePath == v.meetings.appendingPathComponent(newName))
        #expect(fmValue(try read(out.filePath), "source_file") == "source_file: \"\(newName)\"")
        #expect(dirContents(v.voice).isEmpty)
    }

    @Test func everyMoveFailingLeavesSourceFileUntouched() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let before = try read(snap.filePath)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v)) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(out.filePath == snap.filePath)
        let after = try read(out.filePath)
        #expect(fmValue(after, "source_file") == "source_file: \"\(snap.filePath.lastPathComponent)\"",
                "the note must never claim a name it doesn't have")
        #expect(after == (try retypedInPlace(before)), "fully re-typed, source_file never rewritten")
        #expect(dirContents(v.meetings) == [snap.filePath.lastPathComponent], "no tmp debris")
    }

    @Test func crashBetweenRewriteAndMoveLeavesSelfConsistentNote() async throws {
        // The pre-move on-disk state is what a crash between the content rewrite
        // and the move would freeze. Capture it from inside the move seam: the
        // note at its ORIGINAL path must already be a complete memo, and its
        // `source_file:` must still name that original path — never the
        // destination it hasn't reached yet.
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        let originalName = snap.filePath.lastPathComponent
        let before = try read(snap.filePath)
        let expectedOnDisk = try retypedInPlace(before)

        struct SimulatedCrash: Error {}
        var seamCalls = 0
        var firstFrom: URL?
        var onDiskAtMove: String?
        var meetingsAtMove: [String] = []
        let meetings = v.meetings

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v)) { from, _ in
            seamCalls += 1
            if seamCalls == 1 {
                firstFrom = from
                onDiskAtMove = try? String(contentsOf: from, encoding: .utf8)
                meetingsAtMove = ((try? FileManager.default.contentsOfDirectory(atPath: meetings.path)) ?? []).sorted()
            }
            throw SimulatedCrash()
        }

        #expect(firstFrom == snap.filePath, "the move starts from the original path")
        let atMove = try #require(onDiskAtMove, "note readable at its original path at the move")
        #expect(fmValue(atMove, "source_file") == "source_file: \"\(originalName)\"",
                "pre-move note must claim the name it actually has")
        #expect(atMove == expectedOnDisk, "pre-move note is fully re-typed; nothing else changed")
        let fm = frontmatterLines(atMove)
        #expect(fm.contains("type: fleeting"))
        #expect(fm.contains("source_app: \"Voice Memo\""))
        #expect(fm.contains("  - log/voice"))
        #expect(fm.contains("  - source/voice"))
        #expect(atMove.contains("\n# Voice Memo — "))
        #expect(meetingsAtMove == [originalName], "only the note, no tmp debris, at the crash point")

        // And with every move failing, that is exactly the state left behind.
        #expect(out.filePath == snap.filePath)
        #expect(try read(snap.filePath) == expectedOnDisk)
        #expect(TranscriptFinalizer.relocateRenamedNote(from: snap.filePath) == nil,
                "still at its own path — nothing to relocate")
    }

    @Test func sourceFilePatchFailureAfterMoveIsNonFatal() async throws {
        // Move succeeds, then the destination folder turns read-only: the
        // step-5 `source_file:` write fails. That write is best-effort — the
        // retype still returns the moved, fully re-typed memo.
        let v = try makeVault()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v.voice.path)
            TestSupport.remove(v.root)
        }
        let snap = try await makeCallNote(in: v.meetings)
        let before = try read(snap.filePath)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v)) { from, to in
            try FileManager.default.moveItem(at: from, to: to)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: to.deletingLastPathComponent().path)
        }

        let newName = "\(datePrefix) Voice Memo.md"
        #expect(out.filePath == v.voice.appendingPathComponent(newName))
        #expect(try read(out.filePath) == (try retypedInPlace(before)),
                "a failed source_file: patch leaves the step-3 content intact")
        #expect(dirContents(v.voice) == [newName], "no tmp debris")
        #expect(dirContents(v.meetings).isEmpty)
    }

    @Test func externallyRenamedNoteWithFailedMoveKeepsOriginalSourceFile() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        try FileManager.default.createDirectory(at: v.voice, withIntermediateDirectories: true)
        // Force a suffixed destination so source_file gets patched, then fail the move.
        try "x\n".write(to: v.voice.appendingPathComponent("2026 Weekly Sync.md"), atomically: true, encoding: .utf8)
        let base = try await makeCallNote(in: v.meetings)
        let renamed = v.meetings.appendingPathComponent("2026 Weekly Sync.md")
        try FileManager.default.moveItem(at: base.filePath, to: renamed)
        let snap = base.relocated(to: renamed)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v)) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(out.filePath == renamed)
        #expect(fmValue(try read(renamed), "source_file") == "source_file: \"\(base.filePath.lastPathComponent)\"",
                "never rewritten — the external pipeline's correlation key")
    }

    @Test func missingNoteThrowsReadFailedAndTouchesNothing() async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = TestSupport.snapshot(filePath: v.meetings.appendingPathComponent("gone.md"))

        expectReadFailed { () throws(PostProcessingError) in
            _ = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))
        }
        #expect(!exists(v.voice), "a failed read must not create the voice folder")
        #expect(dirContents(v.meetings).isEmpty)
    }

    // MARK: - Externally linked notes

    @Test(arguments: [
        ["meeting_note: \"[[Weekly Sync]]\"", "pipeline_state: titled"],
        ["meeting_note: \"[[Weekly Sync]]\""],
        ["pipeline_state: titled"],
    ])
    func linkedNoteIsRetypedInPlaceNotMoved(injected: [String]) async throws {
        let v = try makeVault()
        defer { TestSupport.remove(v.root) }
        let snap = try await makeCallNote(in: v.meetings)
        var content = try read(snap.filePath)
        content = try replacingFirst(
            "session_guid: \"retype-guid\"\n",
            with: "session_guid: \"retype-guid\"\n" + injected.map { $0 + "\n" }.joined(),
            in: content
        )
        try content.write(to: snap.filePath, atomically: true, encoding: .utf8)

        let out = try TranscriptFinalizer.retypeAsVoiceMemo(snapshot: snap, plan: plan(v))

        #expect(out.filePath == snap.filePath, "a note an external pipeline bound stays where it put it")
        let after = try read(out.filePath)
        let fm = frontmatterLines(after)
        #expect(fm.contains("type: fleeting"))
        #expect(fm.contains("source_app: \"Voice Memo\""))
        #expect(fm.contains("  - log/voice"))
        #expect(fm.contains("  - source/voice"))
        #expect(after.contains("\n# Voice Memo — "))
        #expect(fmValue(after, "source_file") == "source_file: \"\(snap.filePath.lastPathComponent)\"")
        for line in injected { #expect(fm.contains(line)) }
        #expect(!exists(v.voice), "voice folder must not even be created")
    }
}
