import Foundation
import Testing
@testable import Tome

/// The logger must never clobber an existing vault note, and its snapshot must
/// faithfully report whether any utterances landed (ContentView's failed-start
/// rollback deletes the note only when `speakersDetected` is empty).
@Suite struct TranscriptLoggerTests {

    @Test func repeatedSuggestedFilenameDoesNotClobber() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let first = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, suggestedFilename: "KSP Tag-up")
        await logger.append(speaker: "You", text: "first session body", timestamp: Date())
        _ = await logger.endSession()

        let second = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, suggestedFilename: "KSP Tag-up")
        _ = await logger.endSession()

        #expect(first.lastPathComponent == "KSP Tag-up.md")
        #expect(second.lastPathComponent == "KSP Tag-up-1.md")
        #expect(try String(contentsOf: first, encoding: .utf8).contains("first session body"),
                "the earlier note's content must survive a repeated suggestedFilename")
    }

    @Test func sameSecondTimestampNamesDoNotCollide() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        // Date-only format guarantees a collision within the test's runtime.
        let a = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, filenameDateFormat: "yyyy-MM-dd")
        _ = await logger.endSession()
        let b = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, filenameDateFormat: "yyyy-MM-dd")
        _ = await logger.endSession()

        #expect(a.lastPathComponent != b.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func fallsBackToUniqueSuffixAfterHundredCollisions() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let fm = FileManager.default
        fm.createFile(atPath: vault.appendingPathComponent("Busy.md").path, contents: Data("x".utf8))
        for n in 1...100 {
            fm.createFile(atPath: vault.appendingPathComponent("Busy-\(n).md").path, contents: Data("x".utf8))
        }

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, suggestedFilename: "Busy")
        _ = await logger.endSession()

        #expect(url.lastPathComponent.hasPrefix("Busy-"))
        #expect(!(1...100).map { "Busy-\($0).md" }.contains(url.lastPathComponent))
        // Every pre-existing file untouched.
        #expect(try String(contentsOf: vault.appendingPathComponent("Busy.md"), encoding: .utf8) == "x")
    }

    @Test func snapshotReportsWhetherUtterancesLanded() async throws {
        // ContentView.rollbackFailedStart keys its note deletion off
        // `speakersDetected.isEmpty` — pin that contract.
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        _ = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        let empty = await logger.endSession()
        #expect(try #require(empty).speakersDetected.isEmpty)

        _ = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        await logger.append(speaker: "You", text: "words", timestamp: Date())
        let nonEmpty = await logger.endSession()
        #expect(!(try #require(nonEmpty).speakersDetected.isEmpty))
    }

    // MARK: - Self-heal on external deletion (incident 2026-07-23)

    @Test func appendAfterExternalDeletionRecreatesNoteWithFullHistory() async throws {
        // Deleting the meeting note in the vault pipeline (WhisperCal) deletes the
        // live transcript mid-session — a supported action. The logger must NOT
        // keep writing into the orphaned inode; it recreates the note (frontmatter
        // + everything recorded so far) and carries on as an unlinked meeting.
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path, sessionGuid: "heal-guid")
        let start = Date()
        await logger.append(speaker: "You", text: "before deletion", timestamp: start)

        try FileManager.default.removeItem(at: url)
        await logger.append(speaker: "Them", text: "after deletion", timestamp: start.addingTimeInterval(5))

        #expect(FileManager.default.fileExists(atPath: url.path), "note must be recreated at the same path")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("before deletion"), "pre-deletion history must be replayed into the recreated note")
        #expect(content.contains("after deletion"))
        #expect(content.contains("session_guid: \"heal-guid\""), "recreated frontmatter must keep the session identity")
        #expect(content.contains("## Transcript"), "recreated note must parse like a live one (finalize anchors on this)")
        #expect(await logger.lastError == nil, "a successful self-heal is not an error state")

        // The session must finalize normally from here.
        let snapshot = await logger.endSession()
        #expect(try #require(snapshot).filePath == url)
    }

    @Test func flushIfNeededRecreatesDeletedNoteWithoutNewUtterances() async throws {
        // The deletion can happen during silence — no append will run, so the
        // timer-cadence flushIfNeeded is the self-heal path.
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        await logger.append(speaker: "You", text: "only utterance", timestamp: Date())

        try FileManager.default.removeItem(at: url)
        await logger.flushIfNeeded()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("only utterance"))
        #expect(await logger.lastError == nil)
        _ = await logger.endSession()
    }

    @Test func missingVaultFolderStillFlagsErrorAndHealsOnRemount() async throws {
        // A missing *folder* is an unmount/eviction, not a note deletion — no
        // recreate (that would write into the dead mountpoint), keep the banner
        // error. When the folder comes back, the next flush self-heals with the
        // full history intact.
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }
        let sub = vault.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: sub.path)
        await logger.append(speaker: "You", text: "kept in memory", timestamp: Date())

        try FileManager.default.removeItem(at: sub)
        await logger.flushIfNeeded()
        #expect(await logger.lastError?.contains("vault may be unmounted") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path), "must not recreate into a missing folder")

        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        await logger.flushIfNeeded()
        #expect(FileManager.default.fileExists(atPath: url.path), "remount heals on the next flush")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("kept in memory"))
        #expect(await logger.lastError == nil)
        _ = await logger.endSession()
    }

    @Test func contextSurvivesRecreation() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        await logger.updateContext("Quarterly planning")
        await logger.append(speaker: "You", text: "hello", timestamp: Date())

        try FileManager.default.removeItem(at: url)
        await logger.append(speaker: "You", text: "world", timestamp: Date())

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("context: \"Quarterly planning\""), "an applied context must survive the rebuild")
        #expect(content.contains("hello"))
        #expect(content.contains("world"))
        _ = await logger.endSession()
    }

    @Test func updateContextLeavesNoStrayTempFiles() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        await logger.append(speaker: "You", text: "before context", timestamp: Date())
        await logger.updateContext("Weekly sync about the widget")
        await logger.append(speaker: "You", text: "after context", timestamp: Date())
        _ = await logger.endSession()

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("context: \"Weekly sync about the widget\""))
        #expect(content.contains("before context"))
        #expect(content.contains("after context"), "handle must survive the context rewrite")

        let strays = try FileManager.default.contentsOfDirectory(atPath: vault.path)
            .filter { $0.hasPrefix(".tome_") }
        #expect(strays.isEmpty, "no temp files left in the vault, got \(strays)")
    }
}
