import Foundation

/// What the session tick should do with the failsafe countdown this second.
enum AutoStopAction: Equatable, Sendable {
    case none
    case beginCountdown(AutoStopReason)
    case cancelCountdown
    case stop(AutoStopReason)
}

/// The forgotten-recording failsafe, as a pure reducer.
///
/// Silence alone means "maybe a pause"; a departure (undock, route change,
/// lock, sleep) alone means "maybe carrying the call elsewhere". Together they
/// are what walking away looks like, so a departure *shortens* the silence
/// window to `departureSilenceSeconds` and turns the outcome into a countdown.
/// Only a long sleep stops on its own.
///
/// No clocks, AppKit or globals: the caller (ContentView's 1 s session tick)
/// injects everything through `Inputs`. The evaluation order in `step` is the
/// specification — see §4 of
/// `docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md`.
/// Every ambiguity is resolved in the direction that keeps recording.
struct AutoStopPolicy: Sendable {
    /// R1: a tick gap at least this long is a sleep nobody is still in a meeting after.
    static let longSleepSeconds = 180
    /// A tick gap at least this long (but below `longSleepSeconds`) is a `.wokeFromSleep` signal.
    static let sleepGapSeconds = 30
    /// How long a departure signal stays relevant.
    static let latchSeconds = 300
    /// R2: trusted silence needed after (or around) a departure.
    static let departureSilenceSeconds = 20
    /// R3: how long the silence prompt must go unanswered.
    static let unansweredPromptSeconds = 600
    /// Visible countdown before a R2/R3 stop.
    static let countdownSeconds = 30
    /// After Keep Recording, signals from the tail of the same burst are dropped.
    static let settleSeconds = 60

    struct Inputs: Sendable {
        var enabled: Bool
        var now: ContinuousClock.Instant
        /// Seconds the Mac slept since the previous tick, floor 1 — see
        /// `tickGapSeconds(previous:now:)`. A frozen main actor is not a sleep.
        var tickGapSeconds: Int
        /// Signals that arrived since the previous tick.
        var newSignals: [DepartureSignal]
        /// The app's existing silence counter.
        var silenceSeconds: Int
        /// The leg being judged delivered a real (tap-written) buffer recently.
        var judgedLegDelivering: Bool
        /// `settings.silenceAutoStopSeconds`; 0 = silence prompt off (and R3 off).
        var silencePromptLimit: Int
    }

    struct Countdown: Equatable, Sendable {
        let reason: AutoStopReason
        let deadline: ContinuousClock.Instant
    }

    private struct Latch: Sendable {
        let reason: DepartureSignal
        var expires: ContinuousClock.Instant
    }

    private(set) var countdown: Countdown?
    /// Silence the app can vouch for (§3). R2 and R3 read this, never `silenceSeconds`.
    private(set) var trustedSilenceSeconds: Int = 0
    private var latch: Latch?
    /// Signals arriving at or before this instant are dropped (not deferred).
    private var settleUntil: ContinuousClock.Instant?

    /// The departure signal currently latched, if any (first of its burst).
    var latchedSignal: DepartureSignal? { latch?.reason }
    /// When the current latch lapses (exclusive: expired once `now >= latchExpiry`).
    var latchExpiry: ContinuousClock.Instant? { latch?.expires }

    init() {}

    /// Called once per 1 s session tick. Order is binding (spec §4).
    mutating func step(_ inputs: Inputs) -> AutoStopAction {
        let now = inputs.now

        // 1. Disabled → reset. A countdown that was up gets one cancel so the
        //    caller can tear its surfaces down; after that, silence.
        guard inputs.enabled else {
            let hadCountdown = countdown != nil
            reset()
            return hadCountdown ? .cancelCountdown : .none
        }

        // 2. R1 — long sleep. Ignores silence, latch, countdown and settle window.
        if inputs.tickGapSeconds >= Self.longSleepSeconds {
            return fire(.slept(seconds: inputs.tickGapSeconds))
        }

        // 3. Countdown deadline. The deadline is a clock instant, so a
        //    countdown interrupted by a lid close fires on the first tick after
        //    wake. Precedes the trusted update by design — with one exception:
        //    audio that came back on this very tick (the app's counter is at
        //    zero) falls through to step 8 and cancels. An audible call is
        //    never stopped, not even by a one-second race. A leg that merely
        //    stopped delivering does NOT get this pass, or a wake would
        //    withdraw the countdown it is supposed to complete.
        if let countdown, now >= countdown.deadline, inputs.silenceSeconds > 0 {
            return fire(countdown.reason)
        }

        // 4. A shorter suspension is itself a departure signal. Appended, so an
        //    explicit signal on the same tick is the latch reason.
        var signals = inputs.newSignals
        if inputs.tickGapSeconds >= Self.sleepGapSeconds {
            signals.append(.wokeFromSleep)
        }

        // 5. Trusted silence (§3): one step per tick regardless of gap, capped
        //    by the app's own counter, zeroed by audio or a non-delivering leg.
        if inputs.judgedLegDelivering && inputs.silenceSeconds > 0 {
            trustedSilenceSeconds = min(trustedSilenceSeconds + 1, inputs.silenceSeconds)
        } else {
            trustedSilenceSeconds = 0
        }

        // 6. Latch signals unless inside the settle window opened by Keep.
        if let first = signals.first {
            let settling = settleUntil.map { now <= $0 } ?? false
            if !settling {
                let expires = now + .seconds(Self.latchSeconds)
                if var current = latch, now < current.expires {
                    // Same episode: extend, keep the first reason.
                    current.expires = expires
                    latch = current
                } else {
                    latch = Latch(reason: first, expires: expires)
                }
            }
        }

        // 7. Expired latch → clear.
        if let current = latch, now >= current.expires {
            latch = nil
        }

        // 8. Countdown running: audio (or a leg that stopped delivering)
        //    withdraws it. The latch stays so it can re-arm after a fresh
        //    `departureSilenceSeconds` of trusted silence.
        if countdown != nil {
            if trustedSilenceSeconds == 0 {
                countdown = nil
                return .cancelCountdown
            }
            return .none
        }

        // 9. Arm. A departure reason wins over the catch-all.
        if let current = latch, trustedSilenceSeconds >= Self.departureSilenceSeconds {
            return begin(.departure(current.reason), now: now)
        }
        if inputs.silencePromptLimit > 0,
           trustedSilenceSeconds >= inputs.silencePromptLimit + Self.unansweredPromptSeconds {
            return begin(.unansweredSilence, now: now)
        }
        return .none
    }

    /// The user's Keep Recording on the countdown: clears the countdown and
    /// the latch and opens a settle window so the tail of the same signal
    /// burst cannot raise a second countdown. Trusted silence restarts too —
    /// the caller zeroes `silenceSeconds` alongside this, and the policy does
    /// not rely on it.
    mutating func keepRecording(now: ContinuousClock.Instant) {
        countdown = nil
        latch = nil
        trustedSilenceSeconds = 0
        settleUntil = now + .seconds(Self.settleSeconds)
    }

    /// Session start/stop: back to idle.
    mutating func reset() {
        countdown = nil
        trustedSilenceSeconds = 0
        latch = nil
        settleUntil = nil
    }

    /// One session tick read on both clocks. The continuous clock keeps
    /// counting while the Mac sleeps; the suspending clock does not — the
    /// difference between their gaps is time spent asleep.
    struct TickStamp: Sendable {
        let continuous: ContinuousClock.Instant
        let suspending: SuspendingClock.Instant

        static var now: TickStamp {
            TickStamp(continuous: .now, suspending: .now)
        }
    }

    /// The caller's `tickGapSeconds`: whole seconds the Mac was ASLEEP between
    /// two session ticks, never below 1 (and 1 for a session's first tick).
    /// Deliberately not the raw continuous gap: a main actor that froze for
    /// three minutes (the 2026-07-25 beach-ball shape) produces the same raw
    /// gap as a lid close, and must not read as R1 — a frozen app is not
    /// evidence that anyone left. Both clocks advance through a freeze, so it
    /// subtracts to zero.
    static func tickGapSeconds(previous: TickStamp?, now: TickStamp) -> Int {
        guard let previous else { return 1 }
        let asleep = (now.continuous - previous.continuous) - (now.suspending - previous.suspending)
        let parts = asleep.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(1, Int(seconds.rounded()))
    }

    // MARK: - Private

    /// A stop ends the episode: wipe everything so a following tick (before
    /// the caller has torn the session down) cannot re-fire.
    private mutating func fire(_ reason: AutoStopReason) -> AutoStopAction {
        reset()
        return .stop(reason)
    }

    private mutating func begin(_ reason: AutoStopReason, now: ContinuousClock.Instant) -> AutoStopAction {
        countdown = Countdown(reason: reason, deadline: now + .seconds(Self.countdownSeconds))
        return .beginCountdown(reason)
    }
}
