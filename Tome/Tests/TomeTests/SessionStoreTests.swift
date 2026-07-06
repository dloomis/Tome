import Foundation
import Testing
@testable import Tome

@Suite struct SessionStoreTests {

    @Test func reusedSessionIdAppendsInsteadOfTruncating() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let store = SessionStore(directory: dir)

        await store.startSession(sessionId: "dup")
        await store.appendRecord(SessionRecord(speaker: .you, text: "first-session line", timestamp: Date()))
        await store.endSession()

        // Same id again (second-granular ids, or an API caller repeating one).
        await store.startSession(sessionId: "dup")
        await store.appendRecord(SessionRecord(speaker: .them, text: "second-session line", timestamp: Date()))
        await store.endSession()

        let content = try String(contentsOf: dir.appendingPathComponent("dup.jsonl"), encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2, "journal must accumulate, not truncate: \(content)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // matches SessionStore's encoder
        let records = try lines.map { try decoder.decode(SessionRecord.self, from: Data($0.utf8)) }
        #expect(records[0].text == "first-session line")
        #expect(records[1].text == "second-session line")
    }
}
