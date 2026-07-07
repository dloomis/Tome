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
