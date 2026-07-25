import AppKit
import Foundation

/// The on-ramp to device-backed ("lean-in") call-audio capture: a one-time
/// invitation shown when a mixer that publishes consumable mix devices is
/// running and Tome is still capturing system audio automatically.
///
/// With the exclusion list gone from Settings, this is the only place a mixer
/// user learns the mode exists — hence a prompt rather than a passive hint. It
/// is an INVITATION only: never a gate, never an auto-switch. Automatic mode is
/// verified correct with a router running (far-end audio survives exclusion,
/// 2026-07-24), so a dismissed prompt costs the user nothing.
///
/// Detection is by bundle ID against `mixPublishingMixerBundleIDs`, never by the
/// acoustic router signature (`AudioProcessInspector`): a conferencing app in a
/// live call runs mic input AND audio output too, so the signature would fire
/// this prompt at every plain Teams user.
enum MixerLeanInPrompt {
    /// UserDefaults key holding the bundle IDs already prompted for. An array
    /// (not a bool) so the prompt re-arms for a mixer the user hasn't seen it
    /// for yet — installing Loopback after dismissing the Wave Link prompt is a
    /// new fact, not a repeat.
    static let shownDefaultsKey = "mixerLeanInPromptShown"

    /// Mixers that publish their mixes as consumable virtual input devices —
    /// the strict subset of the router category this feature can serve. Krisp,
    /// Voicemod, G HUB et al. are routers with no mix to subscribe to, so
    /// prompting their users would offer them nothing to select.
    ///
    /// Ship-only-verified, same rule as the exclusion built-ins: an ID that
    /// never matches is a silent no-op. `com.elgato.WaveLink3` verified
    /// on-machine 2026-07-25 (Wave Link 3.x publishes one input device per mix);
    /// `com.elgato.WaveLink` is Elgato's documented 1.x id. Loopback / RØDE
    /// UNIFY join when their IDs are verified against a real install.
    static let mixPublishingMixerBundleIDs: [String] = [
        "com.elgato.WaveLink3",
        "com.elgato.WaveLink",
    ]

    /// Pure decision: which mixer to invite the user to configure, or nil for
    /// "say nothing". Never fires when a device source is already selected (the
    /// user has already found the feature) or when this mixer has been prompted
    /// for before.
    static func mixerToPromptFor(
        runningBundleIDs: [String],
        systemAudioSourceUID: String,
        alreadyPromptedBundleIDs: [String],
        knownMixers: [String] = mixPublishingMixerBundleIDs
    ) -> String? {
        guard systemAudioSourceUID.isEmpty else { return nil }
        let running = Set(runningBundleIDs.map { $0.lowercased() })
        let prompted = Set(alreadyPromptedBundleIDs.map { $0.lowercased() })
        return knownMixers.first {
            running.contains($0.lowercased()) && !prompted.contains($0.lowercased())
        }
    }

    /// Bundle IDs of currently-running apps. `NSWorkspace` only — no new
    /// permissions, and no audio-device enumeration.
    @MainActor
    static func runningApplicationBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    /// Installed display name for a bundle ID, falling back to the ID itself so
    /// the prompt still reads sensibly for an app we can't resolve.
    @MainActor
    static func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Record that the prompt for `bundleID` has been shown and answered
    /// (accepted or dismissed — both are answers; the invitation isn't repeated).
    static func markPrompted(bundleID: String, defaults: UserDefaults = .standard) {
        var shown = defaults.stringArray(forKey: shownDefaultsKey) ?? []
        guard !shown.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        shown.append(bundleID)
        defaults.set(shown, forKey: shownDefaultsKey)
    }

    static func promptedBundleIDs(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: shownDefaultsKey) ?? []
    }
}
