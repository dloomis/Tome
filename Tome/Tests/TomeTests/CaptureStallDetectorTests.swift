import Foundation
import Testing
@testable import Tome

/// Pure stall-detection policy used by the engine's capture watchdog for BOTH
/// legs (mic and system audio). The old watchdog covered only system audio and
/// only ever set an error string; this drives per-leg stall/resume events.
@Suite struct CaptureStallDetectorTests {

    @Test func quietUnderThreshold() {
        var d = CaptureStallDetector(threshold: 15)
        let now = Date()
        #expect(d.evaluate(lastSample: now.addingTimeInterval(-5), now: now) == nil)
        #expect(!d.isStalled)
    }

    @Test func firesOnceWhenGapExceedsThreshold() {
        var d = CaptureStallDetector(threshold: 15)
        let now = Date()
        let stale = now.addingTimeInterval(-20)
        #expect(d.evaluate(lastSample: stale, now: now) == .stalled(gapSeconds: 20))
        #expect(d.isStalled)
        // Still stalled — no duplicate event on subsequent polls.
        #expect(d.evaluate(lastSample: stale, now: now.addingTimeInterval(5)) == nil)
    }

    @Test func resumesAndCanStallAgain() {
        var d = CaptureStallDetector(threshold: 15)
        var now = Date()
        _ = d.evaluate(lastSample: now.addingTimeInterval(-20), now: now)
        #expect(d.isStalled)

        // Samples flow again.
        #expect(d.evaluate(lastSample: now, now: now) == .resumed)
        #expect(!d.isStalled)

        // A second stall episode fires a fresh event.
        now = now.addingTimeInterval(60)
        #expect(d.evaluate(lastSample: now.addingTimeInterval(-16), now: now) == .stalled(gapSeconds: 16))
    }

    @Test func gapExactlyAtThresholdIsNotAStall() {
        var d = CaptureStallDetector(threshold: 15)
        let now = Date()
        #expect(d.evaluate(lastSample: now.addingTimeInterval(-15), now: now) == nil)
        #expect(!d.isStalled)
    }

    @Test func futureLastSampleIsNotAStall() {
        // Wall clock stepped backwards (NTP correction) — never alarm on it.
        var d = CaptureStallDetector(threshold: 15)
        let now = Date()
        #expect(d.evaluate(lastSample: now.addingTimeInterval(30), now: now) == nil)
        #expect(!d.isStalled)
    }

    @Test func nilWhileStalledHoldsTheLatch() {
        // mic.stop() nulls the timestamp during a watchdog-triggered restart;
        // the latch must survive that window or the resume event is lost.
        var d = CaptureStallDetector(threshold: 15)
        let now = Date()
        _ = d.evaluate(lastSample: now.addingTimeInterval(-20), now: now)
        #expect(d.evaluate(lastSample: nil, now: now.addingTimeInterval(5)) == nil)
        #expect(d.isStalled, "latch must survive the restart's nil window")
        #expect(d.evaluate(lastSample: now.addingTimeInterval(10), now: now.addingTimeInterval(10)) == .resumed)
    }

    @Test func seededClockCannotUnlatchWithoutRealSamples() {
        // A restart re-seeds the leg's clock at engine start even when the tap
        // never delivers (the wedge case). A seeded (non-authoritative) fresh
        // timestamp must NOT emit .resumed — otherwise the watchdog cycles
        // restart → phantom resume → restart forever, wiping the stall alert
        // each time while zero audio is recorded.
        var d = CaptureStallDetector(threshold: 15)
        var now = Date()
        _ = d.evaluate(lastSample: now.addingTimeInterval(-20), now: now)
        #expect(d.isStalled)

        // Fresh seeded timestamp, no real samples yet.
        now = now.addingTimeInterval(5)
        #expect(d.evaluate(lastSample: now, now: now, canResume: false) == nil)
        #expect(d.isStalled, "seeded clock must hold the latch")

        // Real tap sample arrives — now it may resume.
        now = now.addingTimeInterval(5)
        #expect(d.evaluate(lastSample: now, now: now, canResume: true) == .resumed)
        #expect(!d.isStalled)
    }

    @Test func nilLastSampleIsNotAStall() {
        // A leg that never delivered (capture still initializing, or intentionally
        // absent) is the caller's problem to seed — the detector stays quiet
        // rather than alarming on nil.
        var d = CaptureStallDetector(threshold: 15)
        #expect(d.evaluate(lastSample: nil, now: Date()) == nil)
        #expect(!d.isStalled)
    }
}
