import Foundation
import Testing
@testable import Tome

/// Pure decision for the mic startup-delivery gate: the one-shot backstop that
/// forces a single mic restart when AirPods' A2DP→HFP renegotiation races the
/// first engine open and the tap never delivers (no error, no config-change
/// notification). The 15s stall watchdog already covers this eventually — the
/// gate collapses that wait to ~3s. Because the wrong call either loops mic
/// restarts or wipes a healthy tap, the branch logic is unit-tested in isolation.
@Suite struct StartupDeliveryGateTests {

    @Test func forcesRestartWhenNeverDeliveredWhileRunning() {
        // Engine up, tap never delivered a sample, gate hasn't fired yet, no
        // rebuild pending — the exact cold-start silence case. Force one restart.
        #expect(TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: true, alreadyFired: false, rebuildInFlight: false
        ))
    }

    @Test func skipsWhenTapAlreadyDelivered() {
        // A single delivered buffer means capture is alive; never rebuild it.
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: Date(), isRunning: true, alreadyFired: false, rebuildInFlight: false
        ))
    }

    @Test func skipsWhenAlreadyFired() {
        // Strictly one-shot per start(): if the forced restart didn't help, the
        // 15s watchdog remains the net — the gate must never loop.
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: true, alreadyFired: true, rebuildInFlight: false
        ))
    }

    @Test func skipsWhenEngineNotRunning() {
        // Session was stopped before the gate fired — nothing to rescue.
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: false, alreadyFired: false, rebuildInFlight: false
        ))
    }

    @Test func skipsWhenRebuildInFlight() {
        // A debounced config/HAL rebuild is already pending — it will re-open the
        // mic on its own. Don't stack a second forced restart on top, even though
        // every other condition matches the cold-start case.
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: true, alreadyFired: false, rebuildInFlight: true
        ))
    }
}
