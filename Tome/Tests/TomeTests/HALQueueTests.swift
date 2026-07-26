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

    @Test func deviceBindFailureDetailsAreDistinctPerCause() {
        let details = Set([
            TranscriptionEngine.bindFailureDetail(.setupFailed("x")),
            TranscriptionEngine.bindFailureDetail(.timedOut),
            TranscriptionEngine.bindFailureDetail(.halWedged),
        ])
        #expect(details.count == 3)
    }
}
