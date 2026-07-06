import Foundation
import Testing
@testable import Tome

/// `tome --selfcheck` — a preflight the user (or CI) can run before an
/// important meeting: structural checks (sessions dir writable, WAV writer
/// round-trip, transcript template write) gate the exit code; environment
/// checks (permissions, model cache, API port) are informational only, so a
/// headless CI runner still exits 0.
@Suite struct SelfCheckTests {

    @Test func passesInAHealthyEnvironment() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let result = SelfCheck.run(sessionsDirectory: dir)
        #expect(result.ok, "structural checks must pass in a writable temp dir:\n\(result.report)")
        #expect(result.report.contains("sessions directory"))
        #expect(result.report.contains("WAV writer"))
    }

    @Test func failsWhenSessionsDirectoryUnwritable() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        // A path nested under a regular file can't be created or written.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)

        let result = SelfCheck.run(sessionsDirectory: blocker.appendingPathComponent("sub"))
        #expect(!result.ok, "unwritable sessions dir is a critical failure:\n\(result.report)")
    }

    @Test func permissionChecksAreInformational() throws {
        // Whatever this machine's TCC state, permission items must never flip
        // the structural verdict — CI runners have no mic or screen access.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let result = SelfCheck.run(sessionsDirectory: dir)
        for item in result.items where !item.critical {
            #expect(result.ok, "informational item '\(item.name)' must not affect ok")
        }
    }
}
