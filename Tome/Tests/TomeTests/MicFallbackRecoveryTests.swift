import Foundation
import Testing
@testable import Tome

/// 2026-10-07 incident: docking mid-start moved the default output onto the
/// pinned Wave XLR, the mic engine died, the rebuild gate read the dead tap as
/// delivering, the watchdog's rebind got HAL 'nope', and the emergency fallback
/// landed on the lid-closed built-in mic — zeros for 63 minutes, because
/// nothing ever retried the pinned device (it never left the device list).
@Suite("Mic fallback retry cadence")
struct MicFallbackRetryIntervalTests {
    @Test func silentFallbackRetriesFastAndCapsAt15s() {
        // A fallback recording zeros costs nothing to interrupt — chase the
        // pinned mic hard.
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 0, fallbackIsSilent: true) == 5)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 1, fallbackIsSilent: true) == 10)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 2, fallbackIsSilent: true) == 15)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 50, fallbackIsSilent: true) == 15)
    }

    @Test func liveFallbackBacksOffAndCapsAtTwoMinutes() {
        // A live fallback is recording the user; each attempt clips a moment
        // of their audio, so attempts must be rare.
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 0, fallbackIsSilent: false) == 30)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 1, fallbackIsSilent: false) == 60)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 3, fallbackIsSilent: false) == 120)
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: 50, fallbackIsSilent: false) == 120)
    }

    @Test func liveIsAlwaysSlowerThanSilent() {
        for attempts in 0..<10 {
            #expect(
                TranscriptionEngine.micFallbackRetryInterval(attempts: attempts, fallbackIsSilent: false)
                    > TranscriptionEngine.micFallbackRetryInterval(attempts: attempts, fallbackIsSilent: true)
            )
        }
    }

    @Test func negativeAttemptsAreTreatedAsFirst() {
        #expect(TranscriptionEngine.micFallbackRetryInterval(attempts: -3, fallbackIsSilent: true) == 5)
    }
}

@Suite("Config-change rebuild gate")
struct TapDeliveredSinceTests {
    private let change = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func lastBufferBeforeTheChangeIsNotDelivery() {
        // The incident shape: last buffer at the change instant-ish, gate
        // evaluated 1.2s later. The old 2s window called this "delivering".
        #expect(!TranscriptionEngine.tapDeliveredSince(change, lastSample: change.addingTimeInterval(-0.05)))
    }

    @Test func aBufferAfterTheChangeProvesTheTapAlive() {
        // The benign case: the notification was informational and the tap
        // kept going (09:59:17 in the same session).
        #expect(TranscriptionEngine.tapDeliveredSince(change, lastSample: change.addingTimeInterval(0.1)))
    }

    @Test func noBufferEverIsNotDelivery() {
        #expect(!TranscriptionEngine.tapDeliveredSince(change, lastSample: nil))
    }

    @Test func aBufferAtTheExactInstantIsNotProof() {
        #expect(!TranscriptionEngine.tapDeliveredSince(change, lastSample: change))
    }
}

@Suite("Lid-closed built-in mic wording")
struct MicLidClosedTextTests {
    @Test func namesTheDeviceAndTheCause() {
        let text = TranscriptionEngine.micLidClosedText(deviceName: "MacBook Pro Microphone", retryingSelection: false)
        #expect(text.contains("MacBook Pro Microphone"))
        #expect(text.contains("lid is closed"))
        #expect(!text.contains("Wave Link"))
    }

    @Test func fallbackWordingSaysTomeIsStillTrying() {
        let text = TranscriptionEngine.micLidClosedText(deviceName: "MacBook Pro Microphone", retryingSelection: true)
        #expect(text.contains("switch back to your selected microphone"))
    }

    @Test func unnamedDeviceStillReadsCleanly() {
        let text = TranscriptionEngine.micLidClosedText(deviceName: nil, retryingSelection: false)
        #expect(text.hasPrefix("The built-in microphone is off"))
    }
}
