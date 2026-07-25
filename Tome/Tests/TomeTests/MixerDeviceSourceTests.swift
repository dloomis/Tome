import CoreAudio
import Foundation
import Testing

@testable import Tome

// Tests for the 2026-07-25 mixer-device spec: the device-backed system leg
// ("lean-in" mode), its fallback surfacing, the shared content counters, and the
// one-time discovery prompt. All pure functions — no audio hardware.
//
// The 2026-07-24 exclusion tests in AudioRouterExclusionTests.swift are retained
// unchanged on purpose: only the exclusion *UI* was removed, the storage,
// seeding, and SCContentFilter behavior all still ship.

@Suite("Call audio source resolution")
struct SystemSourceResolutionTests {
    @Test func emptyUIDIsAutomaticSCK() {
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "", resolvedDeviceID: nil, micDeviceID: 7
        ) == .sck)
    }

    @Test func emptyUIDIgnoresAResolvableDevice() {
        // "" means the user chose automatic; a device that happens to resolve
        // must not sneak the session into device mode.
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "", resolvedDeviceID: 9, micDeviceID: 7
        ) == .sck)
    }

    @Test func resolvableUIDSelectsTheDevice() {
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "wavelink-transcriber", resolvedDeviceID: 9, micDeviceID: 7
        ) == .device(9))
    }

    @Test func absentDeviceFallsBackToSCK() {
        // Mixer driver unloaded / device unplugged: record the session on SCK
        // and say so. The selection is preserved, so the next rebuild re-adopts
        // the device the moment it returns.
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "wavelink-transcriber", resolvedDeviceID: nil, micDeviceID: 7
        ) == .sckFallback(.deviceUnavailable))
    }

    @Test func sameDeviceAsMicIsRefused() {
        // The invariant this guard exists for: one device on both legs means
        // every utterance transcribes twice.
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "mic-only-mix", resolvedDeviceID: 7, micDeviceID: 7
        ) == .sckFallback(.sameAsMic))
    }

    @Test func micDeviceZeroDoesNotCollide() {
        // currentMicDeviceID is 0 when no mic device resolved at all; a real
        // device id can never be 0, so this must still reach device mode.
        #expect(TranscriptionEngine.resolveSystemSource(
            uid: "wavelink-transcriber", resolvedDeviceID: 9, micDeviceID: 0
        ) == .device(9))
    }
}

@Suite("Call audio source fallback messaging")
struct SystemSourceFallbackTextTests {
    @Test func namedDeviceAppearsInTheMessage() {
        let msg = TranscriptionEngine.systemSourceFallbackText(
            reason: .deviceUnavailable, deviceName: "Elgato Wave Link Transcriber"
        )
        #expect(msg.contains("Elgato Wave Link Transcriber"))
        #expect(msg.contains("unavailable"))
    }

    @Test func unnamedDeviceStillReadsSensibly() {
        let msg = TranscriptionEngine.systemSourceFallbackText(
            reason: .deviceUnavailable, deviceName: nil
        )
        #expect(!msg.isEmpty)
        #expect(!msg.contains("nil"))
    }

    @Test func sameAsMicExplainsTheDoubleCapture() {
        let msg = TranscriptionEngine.systemSourceFallbackText(reason: .sameAsMic, deviceName: "Mic Only")
        #expect(msg.lowercased().contains("microphone"))
    }

    @Test func everyReasonHasDistinctText() {
        let all: [TranscriptionEngine.SystemSourceFallbackReason] = [.deviceUnavailable, .sameAsMic, .bindFailed]
        let texts = Set(all.map { TranscriptionEngine.systemSourceFallbackText(reason: $0, deviceName: "Mix") })
        #expect(texts.count == all.count)
    }

    @Test func everyReasonSaysCaptureContinues() {
        // A fallback is never a dead session: the far end is still captured, and
        // the message must not read as "nothing was recorded".
        let all: [TranscriptionEngine.SystemSourceFallbackReason] = [.deviceUnavailable, .sameAsMic, .bindFailed]
        for reason in all {
            let msg = TranscriptionEngine.systemSourceFallbackText(reason: reason, deviceName: "Mix")
            #expect(msg.contains("capturing system audio automatically instead"))
        }
    }
}

@Suite("Silent system-leg notification text")
struct SystemAudioSilentDetailTests {
    @Test func deviceModeNeverPointsAtExclusionSettings() {
        // The exclusion list is inert in device mode — sending the user there
        // would be a dead end. Both device-mode variants must talk about the mix.
        for atStop in [true, false] {
            let msg = TranscriptionEngine.systemAudioSilentDetail(deviceMode: true, atStop: atStop)
            #expect(msg.lowercased().contains("mix"))
            #expect(!msg.contains("Settings"))
        }
    }

    @Test func automaticModePointsAtTheSourceSetting() {
        for atStop in [true, false] {
            let msg = TranscriptionEngine.systemAudioSilentDetail(deviceMode: false, atStop: atStop)
            #expect(msg.contains("Settings"))
        }
    }

    @Test func allFourVariantsAreDistinct() {
        let texts = Set([
            TranscriptionEngine.systemAudioSilentDetail(deviceMode: true, atStop: true),
            TranscriptionEngine.systemAudioSilentDetail(deviceMode: true, atStop: false),
            TranscriptionEngine.systemAudioSilentDetail(deviceMode: false, atStop: true),
            TranscriptionEngine.systemAudioSilentDetail(deviceMode: false, atStop: false),
        ])
        #expect(texts.count == 4)
    }
}

@Suite("Capture content counters")
struct CaptureContentCountersTests {
    @Test func silentBuffersDoNotCountAsAudible() {
        let counters = CaptureContentCounters()
        counters.noteBuffer(rms: 0)
        counters.noteBuffer(rms: 1e-5)  // measured quiet-capture noise floor
        #expect(counters.audibleBufferCount == 0)
    }

    @Test func speechLevelBuffersCount() {
        let counters = CaptureContentCounters()
        counters.noteBuffer(rms: 4e-2)  // measured speech level
        counters.noteBuffer(rms: SystemAudioCapture.audibleRMSThreshold * 2)
        #expect(counters.audibleBufferCount == 2)
    }

    @Test func thresholdIsExclusive() {
        // Both legs must agree on "audible", so the boundary is pinned: the SCK
        // capture uses `rms > threshold`.
        let counters = CaptureContentCounters()
        counters.noteBuffer(rms: SystemAudioCapture.audibleRMSThreshold)
        #expect(counters.audibleBufferCount == 0)
    }

    @Test func writeErrorsAccumulateAndReportTheirTotal() {
        let counters = CaptureContentCounters()
        #expect(counters.noteWriteError() == 1)
        #expect(counters.noteWriteError() == 2)
        #expect(counters.writeErrorCount == 2)
    }

    @Test func resetClearsBothCounters() {
        // A mid-session device rebuild re-enters bufferStream, which resets —
        // the new device must not inherit the old one's accounting.
        let counters = CaptureContentCounters()
        counters.noteBuffer(rms: 1)
        counters.noteWriteError()
        counters.reset()
        #expect(counters.audibleBufferCount == 0)
        #expect(counters.writeErrorCount == 0)
    }

    @Test func micCaptureExposesTheCountersAndStartsAtZero() {
        let capture = MicCapture()
        #expect(capture.audibleBufferCount == 0)
        #expect(capture.writeErrorCount == 0)
    }
}

@Suite("Mixer lean-in prompt")
struct MixerLeanInPromptTests {
    private let mixers = ["com.elgato.WaveLink3", "com.example.Loopback"]

    @Test func promptsForARunningKnownMixer() {
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["com.apple.finder", "com.elgato.WaveLink3"],
            systemAudioSourceUID: "",
            alreadyPromptedBundleIDs: [],
            knownMixers: mixers
        )
        #expect(result == "com.elgato.WaveLink3")
    }

    @Test func neverPromptsWhenADeviceSourceIsAlreadySelected() {
        // The user already found the feature; the invitation is noise.
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["com.elgato.WaveLink3"],
            systemAudioSourceUID: "wavelink-transcriber",
            alreadyPromptedBundleIDs: [],
            knownMixers: mixers
        )
        #expect(result == nil)
    }

    @Test func isOneShotPerMixer() {
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["com.elgato.WaveLink3"],
            systemAudioSourceUID: "",
            alreadyPromptedBundleIDs: ["com.elgato.WaveLink3"],
            knownMixers: mixers
        )
        #expect(result == nil)
    }

    @Test func reArmsForADifferentMixer() {
        // Installing a second mixer after dismissing the first is a new fact.
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["com.elgato.WaveLink3", "com.example.Loopback"],
            systemAudioSourceUID: "",
            alreadyPromptedBundleIDs: ["com.elgato.WaveLink3"],
            knownMixers: mixers
        )
        #expect(result == "com.example.Loopback")
    }

    @Test func ignoresRoutersThatPublishNoMix() {
        // Krisp-class apps are in the exclusion built-ins but have no mix to
        // subscribe to — prompting their users would offer nothing selectable.
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["com.krisp.app", "com.apple.Music"],
            systemAudioSourceUID: "",
            alreadyPromptedBundleIDs: [],
            knownMixers: mixers
        )
        #expect(result == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        let result = MixerLeanInPrompt.mixerToPromptFor(
            runningBundleIDs: ["COM.ELGATO.WAVELINK3"],
            systemAudioSourceUID: "",
            alreadyPromptedBundleIDs: [],
            knownMixers: mixers
        )
        #expect(result == "com.elgato.WaveLink3")
    }

    @Test func shippedMixerListOnlyCarriesVerifiedIDs() {
        // Ship-only-verified rule (2026-07-24): an unverified ID is a silent
        // no-op, i.e. a user who never sees the invitation.
        #expect(MixerLeanInPrompt.mixPublishingMixerBundleIDs.contains("com.elgato.WaveLink3"))
    }
}

@Suite("Call audio source persistence", .serialized)
@MainActor
struct CallAudioSourceSettingsTests {
    /// Save/restore the keys this suite touches so a developer's real defaults
    /// (and the other suites) are unaffected.
    private func withCleanDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["systemAudioSourceUID", "systemAudioSourceName"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body(defaults)
    }

    @Test func freshInstallDefaultsToAutomatic() {
        withCleanDefaults { _ in
            let settings = AppSettings()
            #expect(settings.systemAudioSourceUID == "")
            #expect(settings.systemAudioSourceName == "")
        }
    }

    @Test func selectionRoundTripsThroughUserDefaults() {
        withCleanDefaults { defaults in
            let settings = AppSettings()
            settings.systemAudioSourceUID = "wavelink-transcriber"
            settings.systemAudioSourceName = "Elgato Wave Link Transcriber"
            #expect(defaults.string(forKey: "systemAudioSourceUID") == "wavelink-transcriber")

            let reloaded = AppSettings()
            #expect(reloaded.systemAudioSourceUID == "wavelink-transcriber")
            #expect(reloaded.systemAudioSourceName == "Elgato Wave Link Transcriber")
        }
    }

    @Test func selectingASourceDoesNotDisturbExclusionSeeding() {
        // The exclusion list keeps shipping (it is what makes automatic mode
        // safe); picking a device must not churn its storage.
        withCleanDefaults { defaults in
            let settings = AppSettings()
            let before = defaults.stringArray(forKey: "excludedAudioAppIDs") ?? []
            settings.systemAudioSourceUID = "wavelink-transcriber"
            let after = defaults.stringArray(forKey: "excludedAudioAppIDs") ?? []
            #expect(before == after)
            #expect(after.contains("com.elgato.WaveLink3"))
        }
    }
}
