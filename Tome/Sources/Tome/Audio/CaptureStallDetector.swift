import Foundation

/// Pure stall-detection policy for one capture leg (mic or system audio).
/// The engine's watchdog polls each leg's last-sample timestamp through one of
/// these; the latch ensures a stall alarms once per episode and clears itself
/// when samples resume, so the watchdog can notify without spamming.
struct CaptureStallDetector {
    let threshold: TimeInterval
    private(set) var isStalled = false

    enum Event: Equatable {
        case stalled(gapSeconds: Int)
        case resumed
    }

    /// Feed the leg's most recent sample timestamp. `nil` means the leg hasn't
    /// delivered yet (capture initializing, or intentionally absent) — callers
    /// seed the timestamp at capture start, so nil is never treated as a stall.
    ///
    /// `canResume`: pass false when `lastSample` is a *seeded* clock (set at
    /// engine start) rather than a real delivered buffer. A restart re-seeds the
    /// clock even when the tap never delivers — without this gate the watchdog
    /// would cycle restart → phantom resume → restart forever on a wedged
    /// device, withdrawing the stall alert each time while recording nothing.
    mutating func evaluate(lastSample: Date?, now: Date, canResume: Bool = true) -> Event? {
        guard let lastSample else { return nil }
        let gap = now.timeIntervalSince(lastSample)
        if gap > threshold {
            guard !isStalled else { return nil }
            isStalled = true
            return .stalled(gapSeconds: Int(gap))
        }
        if isStalled && canResume {
            isStalled = false
            return .resumed
        }
        return nil
    }
}
