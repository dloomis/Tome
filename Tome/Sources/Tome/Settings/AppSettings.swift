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

    /// Persisted CoreAudio device UID of the selected microphone. Empty string
    /// means "use system default". UIDs (not AudioDeviceIDs) because numeric IDs
    /// are transient — third-party HAL drivers (Wave Link et al.) reassign them
    /// across driver reloads, app restarts, and reboots, which used to reset the
    /// user's selection at every launch. Resolved to a live AudioDeviceID at each
    /// capture bind by `TranscriptionEngine`.
    var inputDeviceUID: String {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }

    /// Last-known display name of the selected mic, so the Settings picker can
    /// show "<name> (unavailable)" while the device is absent instead of going
    /// blank. Maintained alongside `inputDeviceUID` by the picker.
    var inputDeviceName: String {
        didSet { UserDefaults.standard.set(inputDeviceName, forKey: "inputDeviceName") }
    }

    // MARK: - Call Audio Source ("Them" leg)

    /// Persisted CoreAudio device UID the call-audio ("Them") leg captures from.
    /// Empty string = "System audio (automatic)", i.e. ScreenCaptureKit over the
    /// whole display minus the exclusions below — the default and the correct
    /// choice for installs with no audio mixer.
    ///
    /// A non-empty UID selects **lean-in mode**: the user runs a mixer (Elgato
    /// Wave Link, Loopback, RØDE UNIFY) that publishes each mix as a virtual
    /// input device, and hands Tome a mix containing the call audio with their
    /// own mic channel muted. Own-voice bleed then cannot happen by construction
    /// rather than by exclusion, and no Screen Recording permission is needed.
    /// UID (not AudioDeviceID) for the same reason as `inputDeviceUID`: mixer
    /// drivers reassign numeric IDs across reloads. Call captures only — voice
    /// memos have no system leg. Applies at the next session start.
    var systemAudioSourceUID: String {
        didSet { UserDefaults.standard.set(systemAudioSourceUID, forKey: "systemAudioSourceUID") }
    }

    /// Last-known display name of the selected call-audio device, so the picker
    /// can show "<name> (unavailable)" while the device is absent instead of
    /// going blank. Maintained alongside `systemAudioSourceUID` by the picker.
    var systemAudioSourceName: String {
        didSet { UserDefaults.standard.set(systemAudioSourceName, forKey: "systemAudioSourceName") }
    }

    // MARK: - System-Audio Exclusions (audio routers)

    /// Bundle IDs of audio-router apps excluded from system-audio capture.
    /// Routers (Wave Link, Krisp, …) continuously render the user's mic as their
    /// own app audio, which ScreenCaptureKit attributes to them per-process —
    /// without exclusion the user's own voice lands on the "Them" leg (verified
    /// 2026-07-24; see docs/superpowers/specs/2026-07-24-own-voice-bleed-*.md).
    /// Exclusion never drops far-end call audio: SCK attributes that to the
    /// conferencing app's own process.
    ///
    /// No Settings UI as of the 2026-07-25 mixer-device spec: exclusion is an
    /// internal detail of automatic mode (it is inert when
    /// `systemAudioSourceUID` selects a device), and it needs no per-user
    /// decisions now that mixer owners have the source picker instead. Storage,
    /// seeding, and migration are unchanged — prior user additions keep working,
    /// and `defaults write com.dloomis.tome excludedAudioAppIDs -array …`
    /// remains the power-user escape hatch.
    var excludedAudioAppIDs: [String] {
        didSet { UserDefaults.standard.set(excludedAudioAppIDs, forKey: "excludedAudioAppIDs") }
    }

    /// Built-in default exclusions. Only IDs verified against a real install
    /// ship here — an ID that never matches is a silent no-op, i.e. silent
    /// UNprotection. `com.elgato.WaveLink3` verified on-machine 2026-07-24
    /// (Wave Link 3.2.2); `com.elgato.WaveLink` is Elgato's documented 1.x id.
    static let builtinExcludedAudioApps: [String] = [
        "com.elgato.WaveLink3",
        "com.elgato.WaveLink",
    ]

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

    /// Max gap (seconds) between two consecutive same-speaker diarized segments that
    /// still merges them into one transcript block (and one re-transcription span).
    /// Higher = fewer, longer blocks — collapses a speaker's sentence-by-sentence
    /// fragments into a single paragraph and gives Parakeet more context per span.
    /// A different speaker's turn always breaks the run, so this never merges two
    /// people. Consumed in `SegmentReTranscriber`. Default 1.5.
    var diarizationMergeGapSeconds: Double {
        didSet { UserDefaults.standard.set(diarizationMergeGapSeconds, forKey: "diarizationMergeGapSeconds") }
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
        // Mic selection: UID-persisted, with a one-time migration from the
        // legacy raw-AudioDeviceID key (resolvable only if that device happens
        // to be present right now — otherwise fall back to system default,
        // which is what the old boot sanitizer would have done anyway).
        let migratedSelection = Self.migratedInputSelection(
            storedUID: defaults.string(forKey: "inputDeviceUID"),
            storedName: defaults.string(forKey: "inputDeviceName"),
            legacyID: AudioDeviceID(defaults.integer(forKey: "inputDeviceID")),
            resolveUID: MicCapture.deviceUID(for:),
            resolveName: MicCapture.deviceName(for:)
        )
        self.inputDeviceUID = migratedSelection.uid
        self.inputDeviceName = migratedSelection.name
        defaults.set(migratedSelection.uid, forKey: "inputDeviceUID")
        defaults.set(migratedSelection.name, forKey: "inputDeviceName")
        defaults.removeObject(forKey: "inputDeviceID")

        // Call-audio source: "" (automatic / SCK) on a fresh install.
        self.systemAudioSourceUID = defaults.string(forKey: "systemAudioSourceUID") ?? ""
        self.systemAudioSourceName = defaults.string(forKey: "systemAudioSourceName") ?? ""

        // System-audio exclusions: seed built-ins exactly once each. Removals
        // stick — a deleted default stays in the seen list, so a later release
        // adding new defaults can't resurrect it.
        let seeded = Self.seededExclusions(
            current: defaults.stringArray(forKey: "excludedAudioAppIDs"),
            seen: defaults.stringArray(forKey: "excludedAudioAppSeenDefaults"),
            builtins: Self.builtinExcludedAudioApps
        )
        self.excludedAudioAppIDs = seeded.list
        defaults.set(seeded.list, forKey: "excludedAudioAppIDs")
        defaults.set(seeded.seen, forKey: "excludedAudioAppSeenDefaults")
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
        self.diarizationMergeGapSeconds = defaults.object(forKey: "diarizationMergeGapSeconds") == nil
            ? 1.5
            : defaults.double(forKey: "diarizationMergeGapSeconds")
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

    /// Pure mic-selection migration: an already-stored UID always wins; else a
    /// legacy nonzero AudioDeviceID is resolved to its UID if the device is
    /// present right now; else system default (empty UID). Resolvers injected
    /// for testability without audio hardware.
    nonisolated static func migratedInputSelection(
        storedUID: String?,
        storedName: String?,
        legacyID: AudioDeviceID,
        resolveUID: (AudioDeviceID) -> String?,
        resolveName: (AudioDeviceID) -> String?
    ) -> (uid: String, name: String) {
        if let storedUID {
            return (storedUID, storedName ?? "")
        }
        if legacyID != 0, let uid = resolveUID(legacyID) {
            return (uid, resolveName(legacyID) ?? "")
        }
        return ("", "")
    }

    /// Pure exclusion-list seeding: append every builtin not yet in `seen` to
    /// the current list, and record it as seen. User removals stick because
    /// removed IDs remain in `seen`. First run (`current == nil`) seeds all
    /// builtins.
    nonisolated static func seededExclusions(
        current: [String]?,
        seen: [String]?,
        builtins: [String]
    ) -> (list: [String], seen: [String]) {
        var list = current ?? []
        var seenSet = seen ?? []
        for id in builtins where !seenSet.contains(id) {
            seenSet.append(id)
            if !list.contains(id) { list.append(id) }
        }
        return (list, seenSet)
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
