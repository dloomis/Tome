import Foundation
import Testing

@testable import Tome

// Engine-side pieces of the 2026-10-06 forgotten-recording failsafe: the
// `audioDeviceRemoved` device-set diff (§2) and the trusted-silence freshness
// rule (§3). Both are pure statics on TranscriptionEngine — no audio hardware.

@Suite("Input device removal diff")
struct InputDeviceRemovalDiffTests {
    private func diff(_ previous: Set<String>?, _ current: HALQueryResult<Set<String>>) -> (removed: Set<String>, nextSnapshot: Set<String>?) {
        TranscriptionEngine.removedInputDeviceUIDs(previous: previous, current: current)
    }

    @Test func unavailableIsNoEvidenceAndKeepsTheSnapshot() {
        // A refused enumeration must never look like every device vanished,
        // and must not erase what we knew (the next answered diff needs it).
        let result = diff(["builtin", "dock-mic"], .unavailable)
        #expect(result.removed.isEmpty)
        #expect(result.nextSnapshot == ["builtin", "dock-mic"])
    }

    @Test func unavailableWithNoSnapshotStaysUnseeded() {
        let result = diff(nil, .unavailable)
        #expect(result.removed.isEmpty)
        #expect(result.nextSnapshot == nil)
    }

    @Test func nilPreviousOnlySeeds() {
        let result = diff(nil, .answered(["builtin", "wavelink-mix"]))
        #expect(result.removed.isEmpty)
        #expect(result.nextSnapshot == ["builtin", "wavelink-mix"])
    }

    @Test func additionsAloneAreNotARemoval() {
        // Docking is an arrival, never a departure.
        let result = diff(["builtin"], .answered(["builtin", "dock-mic"]))
        #expect(result.removed.isEmpty)
        #expect(result.nextSnapshot == ["builtin", "dock-mic"])
    }

    @Test func unchangedSetRemovesNothing() {
        let result = diff(["builtin"], .answered(["builtin"]))
        #expect(result.removed.isEmpty)
        #expect(result.nextSnapshot == ["builtin"])
    }

    @Test func removalIsReported() {
        // The undock case: the physical dock mic disappears while the mixer's
        // virtual devices stay registered.
        let result = diff(["builtin", "dock-mic", "wavelink-mix"], .answered(["builtin", "wavelink-mix"]))
        #expect(result.removed == ["dock-mic"])
        #expect(result.nextSnapshot == ["builtin", "wavelink-mix"])
    }

    @Test func removalWithSimultaneousAdditionStillReportsTheRemoval() {
        let result = diff(["builtin", "airpods"], .answered(["builtin", "dock-mic"]))
        #expect(result.removed == ["airpods"])
        #expect(result.nextSnapshot == ["builtin", "dock-mic"])
    }

    @Test func enumerationProjectsToUIDsAndPreservesUnavailable() {
        let answered = TranscriptionEngine.inputDeviceUIDs(.answered([
            (id: 1, uid: "builtin", name: "MacBook Pro Microphone"),
            (id: 2, uid: "dock-mic", name: "Dock"),
        ]))
        guard case .answered(let uids) = answered else {
            Issue.record("answered enumeration must stay answered")
            return
        }
        #expect(uids == ["builtin", "dock-mic"])

        guard case .unavailable = TranscriptionEngine.inputDeviceUIDs(.unavailable) else {
            Issue.record("a refused enumeration must stay unavailable, never an empty device set")
            return
        }
    }
}

@Suite("Judged-leg delivery freshness")
struct LegDeliveryFreshnessTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func neverDeliveredIsNotDelivering() {
        #expect(!TranscriptionEngine.legIsDelivering(lastSample: nil, hasDelivered: false, now: now))
    }

    @Test func seededButNotDeliveredIsNotDelivering() {
        // SCK seeds `lastSampleTime` at bufferStream start; without a real
        // buffer (firstSampleTime nil) a fresh-looking seed must not count, or
        // a watchdog rebuild every 15s could accumulate trusted silence.
        #expect(!TranscriptionEngine.legIsDelivering(lastSample: now, hasDelivered: false, now: now))
    }

    @Test func deliveredFlagWithoutTimestampIsNotDelivering() {
        #expect(!TranscriptionEngine.legIsDelivering(lastSample: nil, hasDelivered: true, now: now))
    }

    @Test func freshTapBufferIsDelivering() {
        #expect(TranscriptionEngine.legIsDelivering(lastSample: now, hasDelivered: true, now: now))
        #expect(TranscriptionEngine.legIsDelivering(
            lastSample: now.addingTimeInterval(-4.9), hasDelivered: true, now: now
        ))
    }

    @Test func staleAtTheFiveSecondBoundary() {
        #expect(TranscriptionEngine.legDeliveryFreshness == 5)
        #expect(!TranscriptionEngine.legIsDelivering(
            lastSample: now.addingTimeInterval(-5), hasDelivered: true, now: now
        ))
        #expect(!TranscriptionEngine.legIsDelivering(
            lastSample: now.addingTimeInterval(-60), hasDelivered: true, now: now
        ))
    }
}
