import Foundation
import os
import Testing

@testable import Tome

// Tests for the 2026-07-25 main-thread capture-bind hang fix: the serial HAL
// executor's deadline + wedge-latch behavior (fault-injected with slow work,
// per the spec's test plan — no real wedged driver needed), the pure outcome
// decision, and the Part C timeout policies.
//
// Serialized: the wedge latch is process-global by design, so these tests
// must not interleave with each other.

@Suite("HAL queue deadline and wedge latch", .serialized)
struct HALQueueTests {
    @Test func fastWorkCompletesWithItsResult() async {
        let outcome = await HALQueue.run(label: "test-fast", deadline: .seconds(5)) { 42 }
        guard case .completed(let value) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(value == 42)
        #expect(!HALQueue.isWedged)
    }

    @Test func slowWorkTimesOutLatchesRefusesThenClears() async throws {
        // Fault injection: a "bind" that blocks past the deadline, standing in
        // for AVAudioEngine.start() against a wedged driver.
        let abandonedResult = OSAllocatedUnfairLock<Int?>(uncheckedState: nil)
        let outcome = await HALQueue.run(
            label: "test-slow",
            deadline: .milliseconds(80),
            work: { () -> Int in
                Thread.sleep(forTimeInterval: 0.5)
                return 7
            },
            onAbandoned: { value in
                abandonedResult.withLock { $0 = value }
            }
        )
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        // The wait was abandoned but the work is still stuck: the latch is up,
        // and further HAL work must fail fast instead of queueing behind it.
        #expect(HALQueue.isWedged)
        let refused = await HALQueue.run(label: "test-refused", deadline: .seconds(5)) { 1 }
        guard case .wedged = refused else {
            Issue.record("expected .wedged while latched, got \(refused)")
            return
        }
        #expect(abandonedResult.withLock { $0 } == nil)

        // When the driver "releases" the call, the latch clears and the
        // abandoned handler receives the orphaned result.
        try await Task.sleep(for: .milliseconds(700))
        #expect(!HALQueue.isWedged)
        #expect(abandonedResult.withLock { $0 } == 7)

        // The queue is usable again.
        let after = await HALQueue.run(label: "test-after", deadline: .seconds(5)) { 3 }
        guard case .completed(let value) = after else {
            Issue.record("expected .completed after latch cleared, got \(after)")
            return
        }
        #expect(value == 3)
    }

    @Test func enumerateDegradesToFallbackOnTimeout() async throws {
        let result = await HALQueue.enumerate(
            label: "test-enumerate-slow",
            deadline: .milliseconds(80),
            fallback: [Int]()
        ) { () -> [Int] in
            Thread.sleep(forTimeInterval: 0.4)
            return [1, 2, 3]
        }
        #expect(result.isEmpty)
        // Let the stuck enumeration drain so the latch doesn't leak into
        // other tests.
        try await Task.sleep(for: .milliseconds(600))
        #expect(!HALQueue.isWedged)
    }

    @Test func wedgeClearPostsTheRecoveryNotification() async throws {
        // The 2026-07-26 stale-pickers regression guard: consumers that
        // degraded while wedged (Settings device enumeration) have no other
        // signal to retry on — the clear is not a device-set change.
        let posted = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: HALQueue.wedgeClearedNotification, object: nil, queue: nil
        ) { _ in posted.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        let outcome = await HALQueue.run(
            label: "test-notify",
            deadline: .milliseconds(80)
        ) { () -> Int in
            Thread.sleep(forTimeInterval: 0.4)
            return 1
        }
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        // Still stuck: no notification while the latch is up.
        #expect(posted.withLock { $0 } == 0)

        try await Task.sleep(for: .milliseconds(600))
        #expect(!HALQueue.isWedged)
        #expect(posted.withLock { $0 } == 1)

        // A healthy run that never wedged must not post.
        _ = await HALQueue.run(label: "test-notify-clean", deadline: .seconds(5)) { 2 }
        #expect(posted.withLock { $0 } == 1)
    }

    @Test func aWedgedBindDoesNotDisableDeviceQueries() async throws {
        // The 2026-07-27 cascade: one stuck AVAudioEngine.start() used to take
        // enumeration down with it (queries queued behind the bind, timed out,
        // and re-latched), so the Settings pickers went stale exactly when the
        // user needed them to switch off the offending device. The lanes are
        // independent now.
        let outcome = await HALQueue.run(
            label: "test-wedged-bind",
            lane: .bind,
            deadline: .milliseconds(80)
        ) { () -> Int in
            Thread.sleep(forTimeInterval: 0.5)
            return 1
        }
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(HALQueue.isWedged(.bind))
        #expect(!HALQueue.isWedged(.query))

        // A query issued while the bind lane is wedged still gets a real answer.
        let query = await HALQueue.query(label: "test-query-during-bind-wedge") { [4, 5, 6] }
        guard case .answered(let devices) = query else {
            Issue.record("query must not be refused because the BIND lane is wedged, got \(query)")
            return
        }
        #expect(devices == [4, 5, 6])

        try await Task.sleep(for: .milliseconds(700))
        #expect(!HALQueue.isWedged)
    }

    @Test func aWedgedQueryDoesNotDisableBinds() async throws {
        // The converse, and the reason binds keep their own latch: a driver
        // that can't answer a property read may still bind, and binding a
        // DIFFERENT device is the user's escape route from a wedge.
        let outcome = await HALQueue.run(
            label: "test-wedged-query",
            lane: .query,
            deadline: .milliseconds(80)
        ) { () -> Int in
            Thread.sleep(forTimeInterval: 0.5)
            return 1
        }
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(HALQueue.isWedged(.query))
        #expect(!HALQueue.isWedged(.bind))

        let bind = await HALQueue.run(label: "test-bind-during-query-wedge", lane: .bind) { 9 }
        guard case .completed(let value) = bind else {
            Issue.record("bind must not be refused because the QUERY lane is wedged, got \(bind)")
            return
        }
        #expect(value == 9)

        try await Task.sleep(for: .milliseconds(700))
        #expect(!HALQueue.isWedged)
    }

    @Test func queryReportsUnavailableRatherThanAFabricatedAnswer() async throws {
        let result: HALQueryResult<[Int]> = await HALQueue.query(
            label: "test-query-slow",
            deadline: .milliseconds(80)
        ) { () -> [Int] in
            Thread.sleep(forTimeInterval: 0.4)
            return [1, 2, 3]
        }
        guard case .unavailable = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
        // The lossy accessor is opt-in, and only for callers that genuinely
        // treat "no answer" as the fallback.
        #expect(result.value(or: []).isEmpty)

        try await Task.sleep(for: .milliseconds(600))
        #expect(!HALQueue.isWedged)
    }

    @Test func decideOutcomeMatchesTheLatchAndDeadlineRules() {
        guard case .wedged = HALQueue.decideOutcome(wedgedAtSubmit: true, finishedWithinDeadline: true) else {
            Issue.record("wedged at submit must refuse regardless of speed")
            return
        }
        guard case .completed = HALQueue.decideOutcome(wedgedAtSubmit: false, finishedWithinDeadline: true) else {
            Issue.record("healthy fast work must complete")
            return
        }
        guard case .timedOut = HALQueue.decideOutcome(wedgedAtSubmit: false, finishedWithinDeadline: false) else {
            Issue.record("late work must time out")
            return
        }
    }
}

@Suite("Bind timeout policy (Part C)")
struct BindTimeoutPolicyTests {
    @Test func onlyCleanSetupFailuresMayCascadeToTheDefaultMic() {
        // The incident regression guard: a timed-out bind retried against the
        // system default just re-queues behind the same wedged driver (the
        // default usually IS the wedged device).
        #expect(TranscriptionEngine.shouldAttemptDefaultFallback(after: .setupFailed("no HAL input")))
        #expect(!TranscriptionEngine.shouldAttemptDefaultFallback(after: .timedOut))
        #expect(!TranscriptionEngine.shouldAttemptDefaultFallback(after: .halWedged))
    }

    @Test func micBindFailureTextIsActionableForAWedge() {
        let msg = TranscriptionEngine.micBindFailureText(error: .timedOut, deviceName: "Elgato Wave Link Mic Only")
        #expect(msg.contains("Elgato Wave Link Mic Only"))
        #expect(msg.contains("isn't responding"))
        #expect(msg.contains("Try again"))
    }

    @Test func micBindFailureTextPassesSetupMessagesThrough() {
        let msg = TranscriptionEngine.micBindFailureText(
            error: .setupFailed("Failed to set mic device 9: OSStatus -10851"),
            deviceName: "Any"
        )
        #expect(msg == "Failed to set mic device 9: OSStatus -10851")
    }

    @Test func micBindFailureTextReadsSensiblyWithoutADeviceName() {
        let msg = TranscriptionEngine.micBindFailureText(error: .halWedged, deviceName: nil)
        #expect(!msg.isEmpty)
        #expect(!msg.contains("nil"))
    }

    @Test func anUnansweredLookupNeverSubstitutesADevice() {
        // The 2026-07-27 regression guard. A refused UID lookup is not evidence
        // that the mic is gone, and reacting to it by binding the system
        // default aims the retry at the wedged device (on the repro machine the
        // selection IS the default).
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "wave-link-mic-only", selectionLookup: .unavailable)
                == .abort
        )
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "", selectionLookup: .unavailable)
                == .abort
        )
    }

    @Test func anAbsentSelectionStillFallsBackToTheDefault() {
        // The pre-existing behavior this must not break: a device that really
        // is unplugged falls back for the session, banner and all.
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "unplugged-usb-mic", selectionLookup: .answered(nil))
                == .useSystemDefault
        )
    }

    @Test func aResolvedSelectionBindsThatDevice() {
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "wave-link-mic-only", selectionLookup: .answered(145))
                == .bind(145)
        )
        // System Default selected: the caller passes the default lookup, and a
        // nil answer means "no default", not "selection absent" — there is no
        // selection to fall back FROM.
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "", selectionLookup: .answered(119))
                == .bind(119)
        )
        #expect(
            TranscriptionEngine.resolveMicTarget(selectedUID: "", selectionLookup: .answered(nil))
                == .bind(nil)
        )
    }

    @Test func deviceBindFailureDetailsAreDistinctPerCause() {
        let details = Set([
            TranscriptionEngine.bindFailureDetail(.setupFailed("x")),
            TranscriptionEngine.bindFailureDetail(.timedOut),
            TranscriptionEngine.bindFailureDetail(.halWedged),
        ])
        #expect(details.count == 3)
    }
}
