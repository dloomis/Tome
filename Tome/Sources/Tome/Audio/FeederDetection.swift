import Foundation

/// Whether anything is feeding a virtual capture device, judged from the
/// process table rather than from sample content.
///
/// The digital-silence checks' original premise — "exact zeros mean unfed" —
/// is unsound: a Wave Link mute renders exact zeros into a *fed* mic mix, and
/// a mix carrying only app channels (the recommended Transcriber setup) is
/// exact zeros until the far end produces sound. Silence content can never
/// distinguish "unfed" from "fed but quiet"; the mixer's process can. See
/// docs/superpowers/specs/2026-07-25-digital-silence-false-positives-feeder-detection.md.
enum FeederVerdict: Equatable, Sendable {
    /// The device's publishing mixer is running — zeros are content (a muted
    /// channel, a call nobody has joined yet), not a fault.
    case fed
    /// The device belongs to a known mixer whose app is NOT running: it stays
    /// registered in CoreAudio and delivers zeros forever. `mixerName` is the
    /// app's display name, so message text can say what to launch.
    case unfed(mixerName: String)
    /// Not attributable to any known mixer. HAL plugin devices are owned by
    /// coreaudiod — there is no owner-process property — so name matching
    /// against known mixers is the best attribution available.
    case unknown
}

enum FeederDetection {
    /// How a known mixer's published devices are recognized. Ship-only-verified,
    /// same rule as `mixPublishingMixerBundleIDs`: a prefix that never matches
    /// is a silent no-op (the verdict stays `.unknown` and the silence checks
    /// keep their hedged wording).
    struct MixerSignature: Sendable {
        /// Display name used in message text ("Wave Link isn't running — …").
        let displayName: String
        /// Case-insensitive prefix of every device the mixer publishes.
        /// Verified on-machine 2026-07-25: Wave Link 3.x names its virtual
        /// inputs "Elgato Wave Link <mix name>".
        let deviceNamePrefix: String
        /// The mixer's bundle IDs — single-sourced from the lean-in prompt's
        /// verified list where the mixer appears there too.
        let bundleIDs: [String]
    }

    static let knownSignatures: [MixerSignature] = [
        MixerSignature(
            displayName: "Wave Link",
            deviceNamePrefix: "Elgato Wave Link",
            bundleIDs: MixerLeanInPrompt.mixPublishingMixerBundleIDs
        )
    ]

    /// Pure verdict: does `deviceName` look like a known mixer's device, and
    /// is that mixer running? All matching is case-insensitive.
    static func verdict(
        deviceName: String?,
        runningBundleIDs: [String],
        signatures: [MixerSignature] = knownSignatures
    ) -> FeederVerdict {
        guard let deviceName, !deviceName.isEmpty else { return .unknown }
        let loweredName = deviceName.lowercased()
        guard let signature = signatures.first(where: { loweredName.hasPrefix($0.deviceNamePrefix.lowercased()) }) else {
            return .unknown
        }
        let running = Set(runningBundleIDs.map { $0.lowercased() })
        let mixerIsRunning = signature.bundleIDs.contains { running.contains($0.lowercased()) }
        return mixerIsRunning ? .fed : .unfed(mixerName: signature.displayName)
    }
}
