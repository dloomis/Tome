import AppKit
import Foundation
import Observation
import CoreAudio

enum SessionType: String {
    case callCapture
    case voiceMemo
}

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var vaultMeetingsPath: String {
        didSet { UserDefaults.standard.set(vaultMeetingsPath, forKey: "vaultMeetingsPath") }
    }

    var vaultVoicePath: String {
        didSet { UserDefaults.standard.set(vaultVoicePath, forKey: "vaultVoicePath") }
    }

    // MARK: - Diarization (SpeakerKit / pyannote v4)

    var diarizationClusterThreshold: Double {
        didSet { UserDefaults.standard.set(diarizationClusterThreshold, forKey: "diarizationClusterThreshold") }
    }

    var diarizationNumberOfSpeakers: Int {
        didSet { UserDefaults.standard.set(diarizationNumberOfSpeakers, forKey: "diarizationNumberOfSpeakers") }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self.vaultMeetingsPath = defaults.string(forKey: "vaultMeetingsPath") ?? NSString("~/Documents/Tome/Meetings").expandingTildeInPath
        self.vaultVoicePath = defaults.string(forKey: "vaultVoicePath") ?? NSString("~/Documents/Tome/Voice").expandingTildeInPath
        self.diarizationClusterThreshold = Self.migratedDouble(defaults, key: "diarizationClusterThreshold", legacyKey: "diarizationThreshold", fallback: 0.7)
        self.diarizationNumberOfSpeakers = Self.migratedInt(defaults, key: "diarizationNumberOfSpeakers", legacyKey: "diarizationMinSpeakers", fallback: 0)
        self.hideFromScreenShare = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
    }

    // MARK: - Legacy Key Migration

    private static func migratedDouble(_ defaults: UserDefaults, key: String, legacyKey: String, fallback: Double) -> Double {
        if defaults.object(forKey: key) != nil { return defaults.double(forKey: key) }
        if defaults.object(forKey: legacyKey) != nil { return defaults.double(forKey: legacyKey) }
        return fallback
    }

    private static func migratedInt(_ defaults: UserDefaults, key: String, legacyKey: String, fallback: Int) -> Int {
        if defaults.object(forKey: key) != nil { return defaults.integer(forKey: key) }
        if defaults.object(forKey: legacyKey) != nil { return defaults.integer(forKey: legacyKey) }
        return fallback
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var vaultMeetingsURL: URL? {
        guard !vaultMeetingsPath.isEmpty else { return nil }
        return URL(fileURLWithPath: vaultMeetingsPath)
    }

    var vaultVoiceURL: URL? {
        guard !vaultVoicePath.isEmpty else { return nil }
        return URL(fileURLWithPath: vaultVoicePath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }
}
