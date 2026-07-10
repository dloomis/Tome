import Foundation
import Testing
@testable import Tome

/// The quit-time emergency flush must complete even while the MAIN THREAD is
/// blocked waiting on it — the old implementation's `Task {}` inherited
/// MainActor isolation and could never start, so every quit burned the full
/// timeout and the flush silently never ran.
@Suite struct TerminationFlushTests {

    @Test @MainActor func flushCompletesWhileMainThreadBlocks() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }
        let sessions = try TestSupport.makeTempDir()
        defer { TestSupport.remove(sessions) }

        let logger = TranscriptLogger()
        _ = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        await logger.append(speaker: "You", text: "last words", timestamp: Date())

        let store = SessionStore(directory: sessions)
        await store.startSession(sessionId: "flush-test")

        // This call runs on the main actor and BLOCKS the main thread — exactly
        // the applicationShouldTerminate condition. It must still return true
        // (flush completed) well inside the timeout.
        let flushed = TerminationFlush.run(logger: logger, store: store, timeout: 2.0)
        #expect(flushed, "flush must complete with the main thread blocked")

        // The flush really ended the session: a second endSession has nothing.
        let leftover = await logger.endSession()
        #expect(leftover == nil, "session should already be closed by the flush")
    }
}
