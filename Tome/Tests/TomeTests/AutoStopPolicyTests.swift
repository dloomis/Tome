import Testing

@testable import Tome

// Truth table for the forgotten-recording failsafe reducer
// (docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md §1, §3, §4,
// "Tests"). §4's evaluation order is the feature: a previous auto-stop in this
// app ended live meetings, so every case below pins either a stop that must
// happen or — more often — one that must NOT.
//
// The harness models the app's 1 s session tick: `t` is seconds since a fixed
// base instant, `silence` mirrors ContentView's `silenceSeconds` (grows by the
// tick gap while silent, zeroes on audio), and every tick feeds the reducer
// exactly what the caller would.

@Suite("Auto-stop policy")
struct AutoStopPolicyTests {
    private struct Harness {
        var policy = AutoStopPolicy()
        let base = ContinuousClock.now
        var t = 0
        var silence = 0
        var delivering = true
        var enabled = true
        var limit = 120

        var now: ContinuousClock.Instant { base + .seconds(t) }

        /// One session tick. `silent` drives the app's silence counter;
        /// `silenceOverride` sets it directly (e.g. a Keep on the silence prompt).
        @discardableResult
        mutating func tick(
            gap: Int = 1,
            signals: [DepartureSignal] = [],
            silent: Bool = true,
            silenceOverride: Int? = nil
        ) -> AutoStopAction {
            t += gap
            if let silenceOverride {
                silence = silenceOverride
            } else {
                silence = silent ? silence + gap : 0
            }
            return policy.step(AutoStopPolicy.Inputs(
                enabled: enabled,
                now: now,
                tickGapSeconds: gap,
                newSignals: signals,
                silenceSeconds: silence,
                judgedLegDelivering: delivering,
                silencePromptLimit: limit
            ))
        }

        /// `n` ordinary 1 s ticks; returns every action in order.
        @discardableResult
        mutating func ticks(_ n: Int, silent: Bool = true) -> [AutoStopAction] {
            (0..<n).map { _ in tick(silent: silent) }
        }

        /// The user's Keep Recording: policy override + the caller zeroing
        /// its silence counter, as ContentView does.
        mutating func keep() {
            policy.keepRecording(now: now)
            silence = 0
        }
    }

    private func allNone(_ actions: [AutoStopAction]) -> Bool {
        actions.allSatisfy { $0 == .none }
    }

    // MARK: - 1. Disabled

    @Test func disabledNeverActsForAnyInputCombination() {
        let gaps = [1, 29, 30, 179, 180, 3600]
        let signalSets: [[DepartureSignal]] = [[], [.displayRemoved], DepartureSignal.allCases]
        for gap in gaps {
            for signals in signalSets {
                for delivering in [true, false] {
                    for limit in [0, 1, 120] {
                        for silence in [0, 19, 20, 5000] {
                            var h = Harness()
                            h.enabled = false
                            h.delivering = delivering
                            h.limit = limit
                            // Pre-roll a long silent stretch so every counter
                            // would be saturated if the policy were listening.
                            for _ in 0..<30 {
                                #expect(h.tick(signals: signals, silenceOverride: silence) == .none)
                            }
                            #expect(h.tick(gap: gap, signals: signals, silenceOverride: silence) == .none)
                            #expect(h.policy.countdown == nil)
                            #expect(h.policy.trustedSilenceSeconds == 0)
                            #expect(h.policy.latchedSignal == nil)
                        }
                    }
                }
            }
        }
    }

    @Test func disablingDuringCountdownCancelsOnceThenGoesQuiet() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        let actions = h.ticks(25)
        #expect(actions.contains(.beginCountdown(.departure(.displayRemoved))))
        #expect(h.policy.countdown != nil)

        h.enabled = false
        #expect(h.tick() == .cancelCountdown)
        #expect(h.policy.countdown == nil)
        #expect(h.policy.latchedSignal == nil)
        #expect(h.policy.trustedSilenceSeconds == 0)
        #expect(allNone(h.ticks(60)))
        // Long sleep while disabled: still nothing.
        #expect(h.tick(gap: 600) == .none)
    }

    @Test func reEnablingStartsFromScratch() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(10)
        h.enabled = false
        h.tick()
        h.enabled = true
        // Latch was wiped by the disable; silence alone (below R3) never arms.
        #expect(allNone(h.ticks(100)))
    }

    // MARK: - 2. Long sleep (R1)

    @Test func longSleepStopsRegardlessOfSilenceLatchOrSettle() {
        for gap in [180, 181, 8 * 3600] {
            for delivering in [true, false] {
                for silent in [true, false] {
                    for withLatch in [true, false] {
                        for inSettle in [true, false] {
                            var h = Harness()
                            h.delivering = delivering
                            if withLatch { h.tick(signals: [.screenLocked]) }
                            if inSettle { h.keep() }
                            #expect(h.tick(gap: gap, silent: silent) == .stop(.slept(seconds: gap)))
                            #expect(h.policy.countdown == nil)
                            #expect(h.policy.latchedSignal == nil)
                        }
                    }
                }
            }
        }
    }

    @Test func longSleepStopFiresOnlyOnce() {
        var h = Harness()
        #expect(h.tick(gap: 600) == .stop(.slept(seconds: 600)))
        // Caller has not torn down yet: following ticks must not re-fire.
        #expect(allNone(h.ticks(30, silent: false)))
    }

    @Test func gapJustBelowLongSleepDoesNotStop() {
        var h = Harness()
        #expect(h.tick(gap: 179) == .none)
        #expect(h.policy.latchedSignal == .wokeFromSleep)
    }

    // MARK: - 3. Short sleep (30–179 s)

    @Test func shortSleepLatchesWokeFromSleepWithoutStopping() {
        for gap in [30, 90, 179] {
            var h = Harness()
            h.delivering = false   // leg mid-rebuild after wake
            #expect(h.tick(gap: gap) == .none)
            #expect(h.policy.latchedSignal == .wokeFromSleep)
            #expect(allNone(h.ticks(120)))
        }
    }

    @Test func gapBelowSleepThresholdIsNotASignal() {
        var h = Harness()
        #expect(h.tick(gap: 29) == .none)
        #expect(h.policy.latchedSignal == nil)
    }

    @Test func shortSleepThenTrustedSilenceCountsDown() {
        var h = Harness()
        #expect(h.tick(gap: 60) == .none)   // trusted 1 (one increment per step)
        let actions = h.ticks(19)
        #expect(actions.last == .beginCountdown(.departure(.wokeFromSleep)))
        #expect(allNone(Array(actions.dropLast())))
    }

    @Test func shortSleepWithAudibleCallNeverArms() {
        var h = Harness()
        h.tick(gap: 60, silent: false)
        #expect(allNone(h.ticks(400, silent: false)))
    }

    // MARK: - 4. Signal + 20 trusted seconds

    @Test func signalPlusTwentyTrustedSecondsBeginsCountdown() {
        var h = Harness()
        h.ticks(5, silent: false)
        #expect(h.tick(signals: [.audioDeviceRemoved]) == .none)   // trusted 1
        let actions = h.ticks(19)                                    // trusted 2…20
        #expect(allNone(Array(actions.dropLast())))
        #expect(actions.last == .beginCountdown(.departure(.audioDeviceRemoved)))
        #expect(h.policy.trustedSilenceSeconds == 20)
        #expect(h.policy.countdown == AutoStopPolicy.Countdown(
            reason: .departure(.audioDeviceRemoved),
            deadline: h.now + .seconds(AutoStopPolicy.countdownSeconds)
        ))
    }

    @Test func signalPlusNineteenTrustedSecondsDoesNothing() {
        var h = Harness()
        h.tick(signals: [.audioDeviceRemoved])
        #expect(allNone(h.ticks(18)))
        #expect(h.policy.trustedSilenceSeconds == 19)
        #expect(h.tick(silent: false) == .none)   // audio at 20: never arms
        #expect(h.policy.trustedSilenceSeconds == 0)
        #expect(h.policy.countdown == nil)
    }

    @Test func signalOnTheTickTrustedReachesTwentyArmsThatTick() {
        var h = Harness()
        #expect(allNone(h.ticks(19)))
        #expect(h.tick(signals: [.outputRouteChanged]) == .beginCountdown(.departure(.outputRouteChanged)))
    }

    // MARK: - 5. Signal while already silent

    @Test func signalWhileAlreadySilentArmsOnThatTick() {
        var h = Harness()
        #expect(allNone(h.ticks(45)))
        #expect(h.tick(signals: [.screenLocked]) == .beginCountdown(.departure(.screenLocked)))
    }

    @Test func trustedNeverExceedsTheAppSilenceCounter() {
        // A caller-side counter that lags (or was just reset) caps trusted.
        var h = Harness()
        h.ticks(30)
        #expect(h.policy.trustedSilenceSeconds == 30)
        h.tick(silenceOverride: 3)
        #expect(h.policy.trustedSilenceSeconds == 3)
        #expect(h.tick(signals: [.screenLocked], silenceOverride: 4) == .none)
    }

    @Test func trustedGrowsOneStepPerTickEvenAcrossAGap() {
        var h = Harness()
        h.ticks(5)
        h.tick(gap: 60)   // silence counter jumps by 60; trusted by 1
        #expect(h.silence == 65)
        #expect(h.policy.trustedSilenceSeconds == 6)
    }

    // MARK: - 6. Latch window

    @Test func silenceStartingFourMinutesAfterSignalStillCountsDown() {
        var h = Harness()
        h.tick(signals: [.displayRemoved], silent: false)   // t = 1
        #expect(allNone(h.ticks(239, silent: false)))       // t = 240
        let actions = h.ticks(20)                           // trusted 20 at t = 260
        #expect(actions.last == .beginCountdown(.departure(.displayRemoved)))
        #expect(allNone(Array(actions.dropLast())))
    }

    @Test func silenceStartingSixMinutesAfterSignalDoesNothing() {
        var h = Harness()
        h.tick(signals: [.displayRemoved], silent: false)
        #expect(allNone(h.ticks(359, silent: false)))
        #expect(allNone(h.ticks(200)))   // well short of R3 (limit 120 + 600)
        #expect(h.policy.latchedSignal == nil)
    }

    @Test func latchExpiresExactlyAtLatchSeconds() {
        // Signal at t = 1 → valid while now < 1 + 300. Expiring on the
        // boundary (not one tick later) is the stop-averse choice.
        // Trusted hits 20 at t = 300 (still < 301): arms.
        var a = Harness()
        a.tick(signals: [.displayRemoved], silent: false)       // t = 1
        a.ticks(279, silent: false)                              // t = 280
        let armed = a.ticks(20)                                  // t = 300
        #expect(armed.last == .beginCountdown(.departure(.displayRemoved)))

        var b = Harness()
        b.tick(signals: [.displayRemoved], silent: false)       // t = 1
        b.ticks(280, silent: false)                              // t = 281
        let late = b.ticks(20)                                   // trusted 20 at t = 301 = expiry
        #expect(allNone(late))
        #expect(b.policy.latchedSignal == nil)
    }

    // MARK: - 7. Trusted silence (unavailable ≠ silent)

    @Test func silenceFromANonDeliveringLegNeverAccumulates() {
        var h = Harness()
        h.delivering = false
        h.tick(signals: [.displayRemoved])
        #expect(allNone(h.ticks(2000)))   // past R3 too
        #expect(h.policy.trustedSilenceSeconds == 0)
    }

    @Test func rebuildReseedPatternNeverReachesTwenty() {
        // Watchdog rebuild re-seeds every 15 s: 5 s "delivering", 10 s not.
        var h = Harness()
        h.delivering = false
        h.tick(signals: [.callSourceLost])
        var maxTrusted = 0
        for second in 0..<1500 {
            h.delivering = (second % 15) < 5
            if second % 240 == 0 {
                // Keep the latch fresh the whole time.
                #expect(h.tick(signals: [.audioDeviceRemoved]) == .none)
            } else {
                #expect(h.tick() == .none)
            }
            maxTrusted = max(maxTrusted, h.policy.trustedSilenceSeconds)
        }
        #expect(maxTrusted == 5)
    }

    @Test func zeroSilenceWhileDeliveringIsNotTrusted() {
        var h = Harness()
        h.tick(signals: [.displayRemoved], silent: false)
        h.ticks(100, silent: false)
        #expect(h.policy.trustedSilenceSeconds == 0)
    }

    // MARK: - 8. Audio resumes during countdown

    @Test func audioDuringCountdownCancelsKeepsLatchAndReArms() {
        var h = Harness()
        h.tick(signals: [.micRouteChanged])
        let armed = h.ticks(19)
        #expect(armed.last == .beginCountdown(.departure(.micRouteChanged)))
        #expect(allNone(h.ticks(10)))   // countdown running, still silent

        #expect(h.tick(silent: false) == .cancelCountdown)
        #expect(h.policy.countdown == nil)
        #expect(h.policy.latchedSignal == .micRouteChanged)

        #expect(allNone(h.ticks(5, silent: false)))
        let rearm = h.ticks(20)
        #expect(allNone(Array(rearm.dropLast())))
        #expect(rearm.last == .beginCountdown(.departure(.micRouteChanged)))
    }

    @Test func legStallDuringCountdownCancels() {
        // Unavailable ≠ silent: a leg that stops delivering mid-countdown is
        // missing evidence, so the countdown is withdrawn.
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        #expect(h.policy.countdown != nil)
        h.delivering = false
        #expect(h.tick() == .cancelCountdown)
        #expect(allNone(h.ticks(200)))
    }

    @Test func cancelFiresOnceNotEveryTick() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        #expect(h.tick(silent: false) == .cancelCountdown)
        #expect(allNone(h.ticks(10, silent: false)))
    }

    // MARK: - 9. Countdown deadline

    @Test func countdownRunsToDeadlineAndStopsExactlyOnce() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        #expect(h.ticks(19).last == .beginCountdown(.departure(.displayRemoved)))
        let running = h.ticks(AutoStopPolicy.countdownSeconds - 1)
        #expect(allNone(running))
        #expect(h.tick() == .stop(.departure(.displayRemoved)))
        #expect(h.policy.countdown == nil)
        #expect(h.policy.latchedSignal == nil)
        // Caller has not torn down yet: no second stop, no new countdown.
        #expect(allNone(h.ticks(60)))
    }

    @Test func audioReturningOnTheDeadlineTickCancelsInsteadOfStopping() {
        // An audible call is never stopped — not even when the audio comes
        // back on the exact tick the deadline passes.
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        h.ticks(AutoStopPolicy.countdownSeconds - 1)
        #expect(h.tick(silent: false) == .cancelCountdown)
        #expect(h.policy.countdown == nil)
        #expect(h.policy.latchedSignal == .displayRemoved)
    }

    // MARK: - 10. Sleep during countdown

    @Test func shortSleepDuringCountdownStopsOnFirstTickWithCountdownReason() {
        for gap in [30, 31, 179] {
            var h = Harness()
            h.tick(signals: [.displayRemoved])
            h.ticks(19)
            h.ticks(3)   // some countdown elapsed
            // Legs are stale right after wake — that must not withdraw the
            // countdown; only audible audio does.
            h.delivering = false
            #expect(h.tick(gap: gap) == .stop(.departure(.displayRemoved)))
            #expect(allNone(h.ticks(10)))
        }
    }

    @Test func audibleCallAtWakeWithdrawsAnInterruptedCountdown() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        h.ticks(3)
        #expect(h.tick(gap: 60, silent: false) == .cancelCountdown)
    }

    @Test func longSleepDuringCountdownStopsAsSlept() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        #expect(h.policy.countdown != nil)
        #expect(h.tick(gap: 900) == .stop(.slept(seconds: 900)))
        #expect(allNone(h.ticks(10)))
    }

    // MARK: - 11. Keep Recording + settle window

    @Test func keepSuppressesSignalsForSixtySecondsThenLatches() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        #expect(h.ticks(19).last == .beginCountdown(.departure(.displayRemoved)))
        h.keep()
        #expect(h.policy.countdown == nil)
        #expect(h.policy.latchedSignal == nil)
        #expect(h.policy.trustedSilenceSeconds == 0)

        // Tail of the undock burst, every tick for 60 s, over continued
        // silence: nothing latches, nothing arms.
        for _ in 0..<60 {
            #expect(h.tick(signals: [.audioDeviceRemoved, .micRouteChanged]) == .none)
        }
        #expect(h.policy.latchedSignal == nil)
        #expect(h.policy.trustedSilenceSeconds == 60)

        // t = keep + 61: a separate departure latches and (trusted ≥ 20) arms.
        #expect(h.tick(signals: [.outputRouteChanged]) == .beginCountdown(.departure(.outputRouteChanged)))
    }

    @Test func settleWindowDropsSyntheticWakeSignal() {
        var h = Harness()
        h.keep()
        #expect(h.tick(gap: 45) == .none)
        #expect(h.policy.latchedSignal == nil)
        #expect(allNone(h.ticks(100)))
    }

    @Test func keepDuringR3CountdownRestartsTheFullWindow() {
        var h = Harness()
        h.limit = 10
        let actions = h.ticks(610)
        #expect(actions.last == .beginCountdown(.unansweredSilence))
        h.keep()
        #expect(allNone(h.ticks(609)))
        #expect(h.tick() == .beginCountdown(.unansweredSilence))
    }

    @Test func keepWithNoCountdownIsHarmless() {
        var h = Harness()
        h.keep()
        #expect(allNone(h.ticks(61, silent: false)))
        #expect(h.tick(signals: [.screenLocked]) == .none)
        #expect(h.policy.latchedSignal == .screenLocked)
    }

    // MARK: - 12. R3 — unanswered silence prompt

    @Test func unansweredPromptArmsAtLimitPlusSixHundred() {
        var h = Harness()
        h.limit = 120
        let actions = h.ticks(720)
        #expect(allNone(Array(actions.dropLast())))
        #expect(actions.last == .beginCountdown(.unansweredSilence))
        #expect(h.policy.trustedSilenceSeconds == 720)
    }

    @Test func unansweredPromptOffWhenLimitIsZero() {
        var h = Harness()
        h.limit = 0
        #expect(allNone(h.ticks(5000)))
    }

    @Test func silencePromptKeepRestartsTheR3Count() {
        // Keep on the *silence prompt* (not the countdown): ContentView zeroes
        // silenceSeconds; trusted follows it to 0 with no extra suppression.
        var h = Harness()
        h.limit = 120
        #expect(allNone(h.ticks(700)))
        h.tick(silenceOverride: 0)
        #expect(h.policy.trustedSilenceSeconds == 0)
        let actions = h.ticks(720)
        #expect(allNone(Array(actions.dropLast())))
        #expect(actions.last == .beginCountdown(.unansweredSilence))
    }

    @Test func r3CountdownCancelsOnAudioAndStopsAtDeadlineOtherwise() {
        var a = Harness()
        a.limit = 30
        #expect(a.ticks(630).last == .beginCountdown(.unansweredSilence))
        #expect(a.tick(silent: false) == .cancelCountdown)

        var b = Harness()
        b.limit = 30
        b.ticks(630)
        #expect(allNone(b.ticks(29)))
        #expect(b.tick() == .stop(.unansweredSilence))
        #expect(allNone(b.ticks(30)))
    }

    @Test func departureReasonWinsWhenBothRulesQualify() {
        var b = Harness()
        b.limit = 1
        b.ticks(600)   // trusted 600, one short of R3
        #expect(b.tick(signals: [.screenLocked]) == .beginCountdown(.departure(.screenLocked)))
    }

    // MARK: - 13. Latch extension

    @Test func secondSignalExtendsLatchButKeepsFirstReason() {
        var h = Harness()
        h.tick(signals: [.displayRemoved], silent: false)        // t = 1, expires 301
        h.ticks(199, silent: false)                               // t = 200
        h.tick(signals: [.screenLocked], silent: false)           // t = 201, expires 501
        #expect(h.policy.latchedSignal == .displayRemoved)
        #expect(h.policy.latchExpiry == h.base + .seconds(501))
        h.ticks(199, silent: false)                               // t = 400, past first expiry
        #expect(h.policy.latchedSignal == .displayRemoved)
        #expect(h.ticks(20).last == .beginCountdown(.departure(.displayRemoved)))
    }

    @Test func firstSignalInATickIsTheReason() {
        var h = Harness()
        h.tick(signals: [.audioDeviceRemoved, .displayRemoved])
        #expect(h.policy.latchedSignal == .audioDeviceRemoved)
    }

    @Test func explicitSignalBeatsSyntheticWakeOnTheSameTick() {
        var h = Harness()
        h.tick(gap: 60, signals: [.screenLocked])
        #expect(h.policy.latchedSignal == .screenLocked)
    }

    @Test func signalAfterExpiryStartsAFreshLatchWithItsOwnReason() {
        var h = Harness()
        h.tick(signals: [.displayRemoved], silent: false)        // expires 301
        h.ticks(299, silent: false)                               // t = 300
        h.tick(signals: [.screenLocked], silent: false)           // t = 301 = expiry
        #expect(h.policy.latchedSignal == .screenLocked)
        #expect(h.policy.latchExpiry == h.base + .seconds(601))
    }

    // MARK: - reset

    @Test func resetClearsEverything() {
        var h = Harness()
        h.tick(signals: [.displayRemoved])
        h.ticks(19)
        h.keep()
        h.tick(signals: [.screenLocked])
        h.policy.reset()
        #expect(h.policy.countdown == nil)
        #expect(h.policy.trustedSilenceSeconds == 0)
        #expect(h.policy.latchedSignal == nil)
        #expect(h.policy.latchExpiry == nil)
        // Settle window gone too: an immediate signal latches.
        h.tick(signals: [.screenLocked])
        #expect(h.policy.latchedSignal == .screenLocked)
    }

    // MARK: - tickGapSeconds (the caller's sleep arithmetic)

    /// A stamp `awake` seconds of running plus `asleep` seconds of sleep after `base`.
    private func stamp(
        after base: AutoStopPolicy.TickStamp, awake: Duration, asleep: Duration = .zero
    ) -> AutoStopPolicy.TickStamp {
        AutoStopPolicy.TickStamp(
            continuous: base.continuous + awake + asleep,
            suspending: base.suspending + awake
        )
    }

    @Test func tickGapIsOneOnTheFirstTick() {
        #expect(AutoStopPolicy.tickGapSeconds(previous: nil, now: .now) == 1)
    }

    @Test func tickGapIsOneForOrdinaryTicksWhateverTheJitter() {
        let base = AutoStopPolicy.TickStamp.now
        for awake in [Duration.zero, .milliseconds(200), .milliseconds(1_040), .milliseconds(1_600)] {
            #expect(AutoStopPolicy.tickGapSeconds(previous: base, now: stamp(after: base, awake: awake)) == 1)
        }
    }

    @Test func frozenMainActorIsNotASleep() {
        // Both clocks advance through a freeze: three minutes — or an hour —
        // of unresponsive app must never read as R1 or as `.wokeFromSleep`.
        let base = AutoStopPolicy.TickStamp.now
        for awake in [Duration.seconds(31), .seconds(200), .seconds(3_600)] {
            let gap = AutoStopPolicy.tickGapSeconds(previous: base, now: stamp(after: base, awake: awake))
            #expect(gap == 1)
            #expect(gap < AutoStopPolicy.sleepGapSeconds)
        }
    }

    @Test func tickGapAcrossALongSleepReachesTheR1Threshold() {
        let base = AutoStopPolicy.TickStamp.now
        let gap = AutoStopPolicy.tickGapSeconds(
            previous: base,
            now: stamp(after: base, awake: .milliseconds(300), asleep: .seconds(14 * 3600))
        )
        #expect(gap == 14 * 3600)
        #expect(gap >= AutoStopPolicy.longSleepSeconds)
        // Just under the threshold stays under it (rounding can't manufacture an R1).
        let under = AutoStopPolicy.tickGapSeconds(
            previous: base,
            now: stamp(after: base, awake: .seconds(1), asleep: .milliseconds(179_400))
        )
        #expect(under < AutoStopPolicy.longSleepSeconds)
    }

    @Test func shortSleepReadsAsItsSleptSecondsOnly() {
        let base = AutoStopPolicy.TickStamp.now
        let gap = AutoStopPolicy.tickGapSeconds(
            previous: base,
            now: stamp(after: base, awake: .seconds(20), asleep: .seconds(45))
        )
        #expect(gap == 45)
    }

    @Test func freshPolicyIsIdle() {
        let p = AutoStopPolicy()
        #expect(p.countdown == nil)
        #expect(p.trustedSilenceSeconds == 0)
        #expect(p.latchedSignal == nil)
    }
}
