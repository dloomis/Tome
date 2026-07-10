import Foundation
import Testing
@testable import Tome

/// Sparkle interlock: update checks (and therefore install/relaunch prompts)
/// must never fire while a recording is live.
@Suite struct UpdatePolicyTests {

    @Test func allowsCheckWhenIdle() {
        #expect(throws: Never.self) { try UpdatePolicy.mayPerformCheck(isRecording: false) }
    }

    @Test func blocksCheckWhileRecording() {
        do {
            try UpdatePolicy.mayPerformCheck(isRecording: true)
            Issue.record("check must be blocked while recording")
        } catch {
            let message = error.localizedDescription.lowercased()
            #expect(message.contains("recording"), "error should explain why: \(error.localizedDescription)")
        }
    }
}
