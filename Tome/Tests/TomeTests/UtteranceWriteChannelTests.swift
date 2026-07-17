import Foundation
import Testing
@testable import Tome

@Suite struct UtteranceWriteChannelTests {

    /// The stop-path barrier: `flush()` must not return until every write
    /// queued before it has been applied to BOTH the markdown transcript and
    /// the JSONL journal — `stopSession` closes those files right after.
    @Test func flushWaitsForAllQueuedWritesToLand() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }
        let sessions = try TestSupport.makeTempDir()
        defer { TestSupport.remove(sessions) }

        let logger = TranscriptLogger()
        let notePath = try await logger.startSession(sourceApp: "Test", vaultPath: vault.path)
        let store = SessionStore(directory: sessions)
        await store.startSession(sessionId: "chan-test")

        let channel = UtteranceWriteChannel(logger: logger, store: store)
        let start = Date()
        for i in 0..<25 {
            channel.write(speaker: .you, text: "line \(i)", timestamp: start.addingTimeInterval(Double(i)))
        }
        await channel.flush()

        // Every write is in the markdown note...
        let note = try String(contentsOf: notePath, encoding: .utf8)
        for i in 0..<25 {
            #expect(note.contains("line \(i)"), "markdown missing utterance \(i)")
        }
        // ...and in the JSONL journal.
        let journal = try String(
            contentsOf: sessions.appendingPathComponent("chan-test.jsonl"), encoding: .utf8)
        #expect(journal.split(separator: "\n").count == 25)

        _ = await logger.endSession()
        await store.endSession()
        channel.shutdown()
    }

    /// Flush with nothing queued returns immediately (stop with no utterances).
    @Test func flushOnIdleChannelReturns() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }
        let sessions = try TestSupport.makeTempDir()
        defer { TestSupport.remove(sessions) }

        let logger = TranscriptLogger()
        let store = SessionStore(directory: sessions)
        let channel = UtteranceWriteChannel(logger: logger, store: store)
        await channel.flush()
        channel.shutdown()
    }

    /// A flush after shutdown must resume, not hang the stop path forever.
    @Test func flushAfterShutdownDoesNotHang() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }
        let sessions = try TestSupport.makeTempDir()
        defer { TestSupport.remove(sessions) }

        let logger = TranscriptLogger()
        let store = SessionStore(directory: sessions)
        let channel = UtteranceWriteChannel(logger: logger, store: store)
        channel.shutdown()
        await channel.flush()
    }
}
