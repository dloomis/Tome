import Foundation
import Testing
@testable import Tome

/// Pure hang-up detector behind the failsafe's log-only `[AUTOSTOP-SHADOW]`
/// probe (spec 2026-10-06 §8). Holds are measured first-seen → last-seen, so a
/// "held N s" process was observed running at t0 and at t0+N.
@Suite struct InputReleaseTrackerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func heldUnderMinimumThenReleasedReportsNothing() {
        var tracker = InputReleaseTracker(excluding: [])
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(0))
        let held = tracker.observe(running: ["us.zoom.xos"], now: at(59))
        #expect(held.newlyHeld.isEmpty)
        let released = tracker.observe(running: [], now: at(64))
        #expect(released.releases.isEmpty)
        #expect(released.newlyHeld.isEmpty)
    }

    @Test func heldMinimumThenReleasedReportsOneReleaseWithDuration() {
        var tracker = InputReleaseTracker(excluding: [])
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(0))
        let held = tracker.observe(running: ["us.zoom.xos"], now: at(60))
        #expect(held.newlyHeld == ["us.zoom.xos"])
        let released = tracker.observe(running: [], now: at(65))
        #expect(released.releases == [.init(bundleID: "us.zoom.xos", heldSeconds: 60)])
        // Released once — a later empty poll reports nothing more.
        #expect(tracker.observe(running: [], now: at(70)).releases.isEmpty)
    }

    @Test func stillRunningReportsNothingAndHoldCrossesOnce() {
        var tracker = InputReleaseTracker(excluding: [])
        var crossings: [String] = []
        for second in stride(from: 0.0, through: 300, by: 5) {
            let observation = tracker.observe(running: ["com.microsoft.teams2"], now: at(second))
            #expect(observation.releases.isEmpty)
            crossings += observation.newlyHeld
        }
        #expect(crossings == ["com.microsoft.teams2"])
    }

    @Test func excludedIDsNeverReportedCaseInsensitively() {
        var tracker = InputReleaseTracker(excluding: ["com.elgato.WaveLink3", "COM.DLOOMIS.TOME"])
        let running: Set<String> = ["com.elgato.wavelink3", "com.dloomis.Tome", "us.zoom.xos"]
        _ = tracker.observe(running: running, now: at(0))
        let held = tracker.observe(running: running, now: at(120))
        #expect(held.newlyHeld == ["us.zoom.xos"])
        let released = tracker.observe(running: [], now: at(125))
        #expect(released.releases.map(\.bundleID) == ["us.zoom.xos"])
    }

    @Test func releaseThenReacquireStartsFreshHold() {
        var tracker = InputReleaseTracker(excluding: [])
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(0))
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(90))
        #expect(tracker.observe(running: [], now: at(95)).releases.count == 1)
        // Re-acquired: the old hold is gone, so 30 s of the new one is too short.
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(100))
        let reHeld = tracker.observe(running: ["us.zoom.xos"], now: at(130))
        #expect(reHeld.newlyHeld.isEmpty)
        #expect(tracker.observe(running: [], now: at(135)).releases.isEmpty)
        // A full new hold reports again, with its own duration and crossing.
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(140))
        #expect(tracker.observe(running: ["us.zoom.xos"], now: at(210)).newlyHeld == ["us.zoom.xos"])
        #expect(tracker.observe(running: [], now: at(215)).releases
            == [.init(bundleID: "us.zoom.xos", heldSeconds: 70)])
    }

    @Test func resetForgetsHoldsAcrossDiscontinuity() {
        var tracker = InputReleaseTracker(excluding: [])
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(0))
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(120))
        tracker.reset()
        // After the discontinuity the process is gone — nothing reported.
        #expect(tracker.observe(running: [], now: at(1_000)).releases.isEmpty)
        // And a process still running after the reset starts a fresh hold.
        _ = tracker.observe(running: ["com.google.Chrome"], now: at(1_005))
        tracker.reset()
        _ = tracker.observe(running: ["com.google.Chrome"], now: at(1_010))
        #expect(tracker.observe(running: [], now: at(1_015)).releases.isEmpty)
    }

    @Test func twoProcessesReleasingOnSamePoll() {
        var tracker = InputReleaseTracker(excluding: [])
        _ = tracker.observe(running: ["us.zoom.xos"], now: at(0))
        _ = tracker.observe(running: ["us.zoom.xos", "com.google.Chrome"], now: at(10))
        let held = tracker.observe(running: ["us.zoom.xos", "com.google.Chrome", "com.apple.FaceTime"], now: at(80))
        #expect(held.newlyHeld == ["com.google.Chrome", "us.zoom.xos"])
        let released = tracker.observe(running: ["com.apple.FaceTime"], now: at(85))
        #expect(released.releases == [
            .init(bundleID: "com.google.Chrome", heldSeconds: 70),
            .init(bundleID: "us.zoom.xos", heldSeconds: 80),
        ])
    }
}
