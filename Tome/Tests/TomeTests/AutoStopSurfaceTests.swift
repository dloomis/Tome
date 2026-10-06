import Foundation
import Testing
@testable import Tome

/// Copy, formatting and pure helpers behind the forgotten-recording failsafe's
/// surfaces (panel, ControlBar row, notifications) — spec
/// `docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md` §6–§7.
@Suite struct AutoStopSurfaceTests {

    // MARK: - countdownLine

    @Test func countdownLineSlept() {
        // Sleep copy doesn't depend on which leg is judged.
        #expect(AutoStopReason.slept(seconds: 600).countdownLine(farEndOnly: false) == "Your Mac was asleep")
        #expect(AutoStopReason.slept(seconds: 600).countdownLine(farEndOnly: true) == "Your Mac was asleep")
    }

    @Test func countdownLineDeparture() {
        let reason = AutoStopReason.departure(.displayRemoved)
        #expect(reason.countdownLine(farEndOnly: false) == "A display was disconnected and it's silent")
        #expect(reason.countdownLine(farEndOnly: true) == "A display was disconnected and the call is silent")
        #expect(AutoStopReason.departure(.screenLocked).countdownLine(farEndOnly: true)
                == "The screen was locked and the call is silent")
    }

    @Test func countdownLineCoversEverySignal() {
        for signal in DepartureSignal.allCases {
            let line = AutoStopReason.departure(signal).countdownLine(farEndOnly: false)
            #expect(line.hasPrefix(signal.userPhrase))
            #expect(line.hasSuffix(" and it's silent"))
        }
    }

    @Test func countdownLineUnansweredSilence() {
        #expect(AutoStopReason.unansweredSilence.countdownLine(farEndOnly: false)
                == "Silence and the stop prompt went unanswered")
        #expect(AutoStopReason.unansweredSilence.countdownLine(farEndOnly: true)
                == "No call audio and the stop prompt went unanswered")
    }

    // MARK: - stoppedDetail

    @Test func stoppedDetailSleptUsesSleepDurationNotSilence() {
        let reason = AutoStopReason.slept(seconds: 14 * 3600)
        let expected = "Your Mac was asleep for 14 hours, so the recording was ended and saved."
        #expect(reason.stoppedDetail(silenceSeconds: 5, farEndOnly: false) == expected)
        #expect(reason.stoppedDetail(silenceSeconds: 5, farEndOnly: true) == expected)
    }

    @Test func stoppedDetailDeparture() {
        let reason = AutoStopReason.departure(.displayRemoved)
        #expect(reason.stoppedDetail(silenceSeconds: 50, farEndOnly: true)
                == "A display was disconnected and the call had been silent for 50 seconds. The recording was saved.")
        #expect(reason.stoppedDetail(silenceSeconds: 50, farEndOnly: false)
                == "A display was disconnected and the recording had been silent for 50 seconds. The recording was saved.")
    }

    @Test func stoppedDetailUnansweredSilence() {
        let reason = AutoStopReason.unansweredSilence
        #expect(reason.stoppedDetail(silenceSeconds: 720, farEndOnly: true)
                == "No call audio for 12 minutes and the stop prompt went unanswered. The recording was saved.")
        #expect(reason.stoppedDetail(silenceSeconds: 720, farEndOnly: false)
                == "No audio for 12 minutes and the stop prompt went unanswered. The recording was saved.")
    }

    // MARK: - duration

    @Test func durationSecondsBoundaries() {
        #expect(AutoStopReason.duration(1) == "1 second")
        #expect(AutoStopReason.duration(0) == "0 seconds")
        #expect(AutoStopReason.duration(-5) == "0 seconds")
        #expect(AutoStopReason.duration(2) == "2 seconds")
        #expect(AutoStopReason.duration(89) == "89 seconds")
    }

    @Test func durationMinutes() {
        #expect(AutoStopReason.duration(90) == "2 minutes")      // 1.5 rounds up
        #expect(AutoStopReason.duration(600) == "10 minutes")
        #expect(AutoStopReason.duration(90 * 60 - 1) == "90 minutes")
    }

    @Test func durationHours() {
        #expect(AutoStopReason.duration(90 * 60) == "2 hours")   // 1.5 h rounds up
        #expect(AutoStopReason.duration(3 * 3600) == "3 hours")
        #expect(AutoStopReason.duration(14 * 3600 + 600) == "14 hours")
    }

    // MARK: - DepartureMonitor

    @Test func displayWasRemovedOnlyWhenCountDrops() {
        #expect(DepartureMonitor.displayWasRemoved(previousCount: 2, currentCount: 1))
        #expect(DepartureMonitor.displayWasRemoved(previousCount: 3, currentCount: 1))
        #expect(!DepartureMonitor.displayWasRemoved(previousCount: 1, currentCount: 1))  // resolution change
        #expect(!DepartureMonitor.displayWasRemoved(previousCount: 1, currentCount: 2))  // display attached
        #expect(!DepartureMonitor.displayWasRemoved(previousCount: 0, currentCount: 0))
    }

    @Test @MainActor func departureMonitorStartStopAreIdempotent() {
        let monitor = DepartureMonitor()
        monitor.stop()
        #expect(!monitor.isRunning)
        monitor.start()
        monitor.start()
        #expect(monitor.isRunning)
        monitor.stop()
        monitor.stop()
        #expect(!monitor.isRunning)
    }

    // MARK: - Countdown formatting

    @Test func formatCountdown() {
        #expect(AutoStopPanelController.formatCountdown(30) == "0:30")
        #expect(AutoStopPanelController.formatCountdown(5) == "0:05")
        #expect(AutoStopPanelController.formatCountdown(0) == "0:00")
        #expect(AutoStopPanelController.formatCountdown(-3) == "0:00")
        #expect(AutoStopPanelController.formatCountdown(75) == "1:15")
    }

    @Test func remainingSecondsRoundsUpAndClamps() {
        let now = ContinuousClock.now
        #expect(AutoStopPanelController.remainingSeconds(until: now + .seconds(30), now: now) == 30)
        #expect(AutoStopPanelController.remainingSeconds(until: now + .milliseconds(29_100), now: now) == 30)
        #expect(AutoStopPanelController.remainingSeconds(until: now + .milliseconds(100), now: now) == 1)
        #expect(AutoStopPanelController.remainingSeconds(until: now, now: now) == 0)
        #expect(AutoStopPanelController.remainingSeconds(until: now - .seconds(4), now: now) == 0)
    }

    // MARK: - Settings

    /// AppSettings hardcodes `.standard` (the test runner's domain, not
    /// Tome's); save and restore the key around the test, as
    /// `TranscriberModelTests` does.
    @Test @MainActor func autoStopWhenAwayDefaultsOnAndPersists() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "autoStopWhenAway")
        defer {
            if let saved { defaults.set(saved, forKey: "autoStopWhenAway") }
            else { defaults.removeObject(forKey: "autoStopWhenAway") }
        }
        defaults.removeObject(forKey: "autoStopWhenAway")
        let settings = AppSettings()
        #expect(settings.autoStopWhenAway)

        settings.autoStopWhenAway = false
        #expect(defaults.object(forKey: "autoStopWhenAway") as? Bool == false)
        #expect(!AppSettings().autoStopWhenAway)
    }
}
