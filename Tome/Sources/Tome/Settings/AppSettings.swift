import AppKit
import Foundation
import FluidAudio
import Observation
import CoreAudio

enum SessionType: String, Sendable, Codable {
    case callCapture
    case voiceMemo
}

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    /// ASR language hint passed to FluidAudio's Parakeet v3 for script-aware token
    /// filtering. Stored as the raw two-letter code ("en", "es", ...). No Settings
    /// UI yet — that lands with a future picker; today the value is effectively a
    /// constant of `.english` for new installs.
    var transcriptionLanguage: Language {
        didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage") }
    }

    /// Which ASR model transcribes. Selection is lazy — changing it triggers a
    /// background download/load via ModelProvisioner; recording is gated until
    /// the selected model is ready. See docs/superpowers/specs/2026-07-08-*.md.
    var transcriberModel: TranscriberModel {
        didSet { UserDefaults.standard.set(transcriberModel.rawValue, forKey: "transcriberModel") }
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

    // MARK: - Recording Retention

    /// When true, each session's combined audio (mic + system for calls, mic for
    /// voice memos) is exported as an `.m4a` to `recordingsFolderPath` after
    /// post-processing. Off by default.
    var retainRecordings: Bool {
        didSet { UserDefaults.standard.set(retainRecordings, forKey: "retainRecordings") }
    }

    var recordingsFolderPath: String {
        didSet { UserDefaults.standard.set(recordingsFolderPath, forKey: "recordingsFolderPath") }
    }

    /// When true, Tome writes a per-speaker voiceprint sidecar (`*.voiceprints.json`)
    /// next to each diarized transcript, carrying an acoustic embedding per remote
    /// speaker for downstream speaker identification. Biometric data — off by default.
    var exportVoiceprints: Bool {
        didSet { UserDefaults.standard.set(exportVoiceprints, forKey: "exportVoiceprints") }
    }

    // MARK: - Discard Short Meetings

    /// When true, a call capture that stops at or under `discardShortMeetingSeconds`
    /// is treated as a canceled / mis-started meeting: its live transcript and capture
    /// files are deleted instead of written to any output folder (no transcript, no
    /// retained recording, no voiceprints). Voice memos are never discarded. Off by
    /// default. The gate lives in `PostProcessingJob.run()`, which measures the session
    /// length and short-circuits before any diarization.
    var discardShortMeetings: Bool {
        didSet { UserDefaults.standard.set(discardShortMeetings, forKey: "discardShortMeetings") }
    }

    /// Call captures at or under this many seconds are discarded when
    /// `discardShortMeetings` is on. Default 30.
    var discardShortMeetingSeconds: Int {
        didSet { UserDefaults.standard.set(discardShortMeetingSeconds, forKey: "discardShortMeetingSeconds") }
    }

    // MARK: - Diarization (SpeakerKit / pyannote v4)

    var diarizationClusterThreshold: Double {
        didSet { UserDefaults.standard.set(diarizationClusterThreshold, forKey: "diarizationClusterThreshold") }
    }

    var diarizationNumberOfSpeakers: Int {
        didSet { UserDefaults.standard.set(diarizationNumberOfSpeakers, forKey: "diarizationNumberOfSpeakers") }
    }

    /// Seconds of continuous silence (mic + system audio both below threshold) before
    /// the active session asks the user to confirm stopping. Recording continues
    /// until the user confirms — silence never stops a session on its own. 0 disables
    /// the prompt entirely. (Key name predates the confirm flow, when this drove a
    /// silent auto-stop.)
    var silenceAutoStopSeconds: Int {
        didSet { UserDefaults.standard.set(silenceAutoStopSeconds, forKey: "silenceAutoStopSeconds") }
    }

    // MARK: - Filename Template

    /// `DateFormatter` pattern used as the date prefix on transcript filenames.
    /// Output is sanitized for filesystem use, so format strings with `/` or `:`
    /// are accepted but converted (e.g. `MM/dd/yy` → `MM-dd-yy`).
    var filenameDateFormat: String {
        didSet { UserDefaults.standard.set(filenameDateFormat, forKey: "filenameDateFormat") }
    }

    /// Label appended after the date for call-capture sessions. Empty string = no label.
    var filenameCallLabel: String {
        didSet { UserDefaults.standard.set(filenameCallLabel, forKey: "filenameCallLabel") }
    }

    /// Label appended after the date for voice-memo sessions. Empty string = no label.
    var filenameVoiceLabel: String {
        didSet { UserDefaults.standard.set(filenameVoiceLabel, forKey: "filenameVoiceLabel") }
    }

    /// When true (default), a Call Capture started from the menu adopts the name of an
    /// auto-detected active meeting (Teams / Google Meet) in place of `filenameCallLabel`.
    /// Per-meeting dismissal and any API-supplied name always take priority.
    var useDetectedMeetingNames: Bool {
        didSet { UserDefaults.standard.set(useDetectedMeetingNames, forKey: "useDetectedMeetingNames") }
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
        self.transcriptionLanguage = (defaults.string(forKey: "transcriptionLanguage").flatMap(Language.init(rawValue:))) ?? .english
        self.transcriberModel = TranscriberModel.from(persisted: defaults.string(forKey: "transcriberModel"))
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self.vaultMeetingsPath = defaults.string(forKey: "vaultMeetingsPath") ?? NSString("~/Documents/Tome/Meetings").expandingTildeInPath
        self.vaultVoicePath = defaults.string(forKey: "vaultVoicePath") ?? NSString("~/Documents/Tome/Voice").expandingTildeInPath
        self.retainRecordings = defaults.bool(forKey: "retainRecordings")
        self.recordingsFolderPath = defaults.string(forKey: "recordingsFolderPath") ?? NSString("~/Documents/Tome/Recordings").expandingTildeInPath
        self.exportVoiceprints = defaults.bool(forKey: "exportVoiceprints")
        self.discardShortMeetings = defaults.bool(forKey: "discardShortMeetings")
        self.discardShortMeetingSeconds = defaults.object(forKey: "discardShortMeetingSeconds") == nil
            ? 30
            : defaults.integer(forKey: "discardShortMeetingSeconds")
        self.diarizationClusterThreshold = Self.migratedDouble(defaults, key: "diarizationClusterThreshold", legacyKey: "diarizationThreshold", fallback: 0.7)
        self.diarizationNumberOfSpeakers = Self.migratedInt(defaults, key: "diarizationNumberOfSpeakers", legacyKey: "diarizationMinSpeakers", fallback: 0)
        self.silenceAutoStopSeconds = defaults.object(forKey: "silenceAutoStopSeconds") == nil
            ? 120
            : defaults.integer(forKey: "silenceAutoStopSeconds")
        self.filenameDateFormat = defaults.string(forKey: "filenameDateFormat") ?? "yyyy-MM-dd HH-mm-ss"
        self.filenameCallLabel = defaults.string(forKey: "filenameCallLabel") ?? "Call Recording"
        self.filenameVoiceLabel = defaults.string(forKey: "filenameVoiceLabel") ?? "Voice Memo"
        self.useDetectedMeetingNames = defaults.object(forKey: "useDetectedMeetingNames") == nil
            ? true
            : defaults.bool(forKey: "useDetectedMeetingNames")
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

    var recordingsFolderURL: URL? {
        guard !recordingsFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: recordingsFolderPath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }
}
