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

    @Test func okIgnoresFailingInformationalItems() {
        // The property the CI smoke test depends on: a headless runner's denied
        // permissions must never flip the structural verdict.
        let check = SelfCheck(items: [
            .init(name: "structural", ok: true, detail: "", critical: true),
            .init(name: "mic", ok: false, detail: "denied", critical: false),
        ])
        #expect(check.ok)
        #expect(check.report.contains("[WARN] mic"))
    }

    @Test func okFailsOnFailingCriticalItem() {
        let check = SelfCheck(items: [.init(name: "dir", ok: false, detail: "", critical: true)])
        #expect(!check.ok)
        #expect(check.report.contains("RESULT: FAIL"))
    }

    @Test func runEmitsInformationalItems() throws {
        // Guards the categorization itself: run() must actually produce
        // non-critical items for the ok-ignores-informational property to matter.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        #expect(SelfCheck.run(sessionsDirectory: dir).items.contains { !$0.critical })
    }

    @Test func failsWhenSessionsPathIsARegularFile() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("occupied")
        try Data("x".utf8).write(to: file)
        #expect(!SelfCheck.run(sessionsDirectory: file).ok)
    }
}
