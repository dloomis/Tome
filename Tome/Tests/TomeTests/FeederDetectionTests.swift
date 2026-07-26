import Testing

@testable import Tome

// Tests for the 2026-07-25 digital-silence false-positive fix: the feeder
// verdict (process-table attribution of a virtual device's silence) and the
// verdict-routed message texts. All pure functions — no audio hardware.

@Suite("Feeder verdict")
struct FeederVerdictTests {
    private let sigs = [
        FeederDetection.MixerSignature(
            displayName: "Wave Link",
            deviceNamePrefix: "Elgato Wave Link",
            bundleIDs: ["com.elgato.WaveLink3", "com.elgato.WaveLink"]
        )
    ]

    @Test func mixerDeviceWithMixerRunningIsFed() {
        // The false-positive scenario from the usability report: muted mic /
        // pre-join mix delivering exact zeros while Wave Link runs. Zeros are
        // content here, not a fault.
        #expect(FeederDetection.verdict(
            deviceName: "Elgato Wave Link Mic Only",
            runningBundleIDs: ["com.apple.finder", "com.elgato.WaveLink3"],
            signatures: sigs
        ) == .fed)
    }

    @Test func mixerDeviceWithoutMixerRunningIsUnfed() {
        // The real failure both silence checks exist for: the device stays
        // registered while its app is closed, delivering zeros forever.
        #expect(FeederDetection.verdict(
            deviceName: "Elgato Wave Link Transcriber",
            runningBundleIDs: ["com.apple.finder"],
            signatures: sigs
        ) == .unfed(mixerName: "Wave Link"))
    }

    @Test func unrecognizedDeviceIsUnknown() {
        // A hardware mic must never be attributed to a mixer — the silence
        // checks keep their hedged wording for it.
        #expect(FeederDetection.verdict(
            deviceName: "MacBook Pro Microphone",
            runningBundleIDs: ["com.elgato.WaveLink3"],
            signatures: sigs
        ) == .unknown)
    }

    @Test func nilAndEmptyNamesAreUnknown() {
        #expect(FeederDetection.verdict(
            deviceName: nil, runningBundleIDs: [], signatures: sigs
        ) == .unknown)
        #expect(FeederDetection.verdict(
            deviceName: "", runningBundleIDs: [], signatures: sigs
        ) == .unknown)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(FeederDetection.verdict(
            deviceName: "ELGATO WAVE LINK MIC ONLY",
            runningBundleIDs: ["COM.ELGATO.WAVELINK3"],
            signatures: sigs
        ) == .fed)
    }

    @Test func anyOfTheMixersBundleIDsCountsAsRunning() {
        // Wave Link 1.x ships a different bundle ID than 3.x; either one
        // running means the device is fed.
        #expect(FeederDetection.verdict(
            deviceName: "Elgato Wave Link Headphones",
            runningBundleIDs: ["com.elgato.WaveLink"],
            signatures: sigs
        ) == .fed)
    }

    @Test func signatureMatchesPrefixOnly() {
        // A device that merely CONTAINS the signature isn't the mixer's.
        #expect(FeederDetection.verdict(
            deviceName: "My Elgato Wave Link Copy",
            runningBundleIDs: [],
            signatures: sigs
        ) == .unknown)
    }

    @Test func shippedSignaturesCoverWaveLink() {
        // Ship-only-verified rule: the one signature we ship must stay wired
        // to the lean-in prompt's verified bundle-ID list, so the two features
        // can never disagree about what "Wave Link is running" means.
        let waveLink = FeederDetection.knownSignatures.first { $0.displayName == "Wave Link" }
        #expect(waveLink?.deviceNamePrefix == "Elgato Wave Link")
        #expect(waveLink?.bundleIDs == MixerLeanInPrompt.mixPublishingMixerBundleIDs)
    }
}

@Suite("Verdict-routed silence message text")
struct SilenceMessageTextTests {
    @Test func unfedMicTextNamesTheMixerAndTheFix() {
        let msg = TranscriptionEngine.micSilenceText(
            deviceName: "Elgato Wave Link Mic Only",
            verdict: .unfed(mixerName: "Wave Link")
        )
        #expect(msg.contains("Wave Link isn't running"))
        #expect(msg.contains("Elgato Wave Link Mic Only"))
        #expect(msg.contains("Launch Wave Link"))
    }

    @Test func unknownMicTextKeepsHedgedWording() {
        // For a device we can't attribute, certainty would be a lie.
        let msg = TranscriptionEngine.micSilenceText(
            deviceName: "Mystery Virtual Mic", verdict: .unknown
        )
        #expect(msg.contains("may be muted"))
        #expect(msg.contains("Mystery Virtual Mic"))
    }

    @Test func unfedSystemTextNamesTheMixerAndTheDevice() {
        let msg = TranscriptionEngine.systemDeviceSilenceText(
            deviceName: "Elgato Wave Link Transcriber",
            verdict: .unfed(mixerName: "Wave Link")
        )
        #expect(msg.contains("Wave Link isn't running"))
        #expect(msg.contains("Elgato Wave Link Transcriber"))
        #expect(msg.contains("Launch Wave Link"))
    }

    @Test func unknownSystemTextKeepsHedgedWording() {
        let msg = TranscriptionEngine.systemDeviceSilenceText(
            deviceName: "Mystery Mix", verdict: .unknown
        )
        #expect(msg.contains("may not be running"))
    }

    @Test func unfedAndUnknownTextsAreDistinct() {
        for name in [String?.some("Mix"), nil] {
            #expect(
                TranscriptionEngine.systemDeviceSilenceText(deviceName: name, verdict: .unfed(mixerName: "Wave Link"))
                    != TranscriptionEngine.systemDeviceSilenceText(deviceName: name, verdict: .unknown)
            )
            #expect(
                TranscriptionEngine.micSilenceText(deviceName: name, verdict: .unfed(mixerName: "Wave Link"))
                    != TranscriptionEngine.micSilenceText(deviceName: name, verdict: .unknown)
            )
        }
    }

    @Test func nilDeviceNamesStillReadSensibly() {
        for msg in [
            TranscriptionEngine.micSilenceText(deviceName: nil, verdict: .unfed(mixerName: "Wave Link")),
            TranscriptionEngine.micSilenceText(deviceName: nil, verdict: .unknown),
            TranscriptionEngine.systemDeviceSilenceText(deviceName: nil, verdict: .unfed(mixerName: "Wave Link")),
            TranscriptionEngine.systemDeviceSilenceText(deviceName: nil, verdict: .unknown),
        ] {
            #expect(!msg.isEmpty)
            #expect(!msg.contains("nil"))
        }
    }

    @Test func micHintIsNeutral() {
        // The hint describes a normal state (muted mic); it must never read
        // like a fault or point fingers at an app.
        let hint = TranscriptionEngine.micSilenceHintText
        #expect(!hint.isEmpty)
        #expect(!hint.lowercased().contains("not running"))
        #expect(!hint.lowercased().contains("error"))
        #expect(!hint.lowercased().contains("fail"))
    }
}
