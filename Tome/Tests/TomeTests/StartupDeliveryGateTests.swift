import Foundation
import Testing
@testable import Tome

/// Pure decision shared by BOTH startup-delivery gates: the one-shot backstop
/// that forces a single restart when a capture leg comes up but never delivers —
/// the mic when AirPods' A2DP→HFP renegotiation races the first engine open, and
/// the system leg when SCStream's cold start succeeds but the tap stays silent
/// (no error, no callback either way). Because the wrong call either loops
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
        // A rebuild is already pending (mic: the debounced config/HAL rebuild;
        // system leg: restartSystemAudioLeg mid-flight) — it will re-open the
        // leg on its own. Don't stack a second forced restart on top, even
        // though every other condition matches the cold-start case.
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: true, alreadyFired: false, rebuildInFlight: true
        ))
    }

    @Test func systemGateCallPattern() {
        // The system gate's exact fire-time call: SCStream came up, the 8s window
        // elapsed, firstSampleTime never set, gate unfired, no rebuild in flight →
        // rebuild once. And the healthy variant — one delivered sample — is a no-op.
        #expect(TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: nil, isRunning: true, alreadyFired: false, rebuildInFlight: false
        ))
        #expect(!TranscriptionEngine.shouldForceStartupRestart(
            firstSampleAt: Date(timeIntervalSinceNow: -6), isRunning: true, alreadyFired: false, rebuildInFlight: false
        ))
    }
}
