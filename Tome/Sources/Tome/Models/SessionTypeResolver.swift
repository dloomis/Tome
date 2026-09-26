import Foundation

/// What the user (or API caller) *asked for* when the session started — the
/// request-time intent, as opposed to `SessionType`, the *resolved* type that
/// is stamped into sidecars, failure markers, handles and notifications.
///
/// `.auto` is the single Record button: capture both legs, write the live note
/// provisionally as a call (the ~95% case), and decide at stop from evidence
/// the session already collected (`SessionTypeResolver`). The explicit modes
/// behave exactly as the two-button UI always has and are never second-guessed.
/// `SessionType` deliberately gains no third case: every persisted artifact
/// keeps its meaning. See
/// docs/superpowers/specs/2026-09-26-single-record-button-auto-mode.md §1.
enum RecordingMode: String, Sendable, Codable {
    /// The single button; resolve the session type at stop.
    case auto
    /// Explicit — behaves exactly as today's Call Capture.
    case callCapture
    /// Explicit — behaves exactly as today's Voice Memo (mic only).
    case voiceMemo

    /// The session type an explicit request pins; nil for `.auto`, whose type
    /// is only known at stop.
    var explicitSessionType: SessionType? {
        switch self {
        case .auto: return nil
        case .callCapture: return .callCapture
        case .voiceMemo: return .voiceMemo
        }
    }

    /// Parses the API's `type` field. Exact, case-sensitive match on the three
    /// tokens only — anything else is nil (the caller answers 400).
    static func fromAPIString(_ raw: String) -> RecordingMode? {
        RecordingMode(rawValue: raw)
    }
}

/// Everything `SessionTypeResolver` looks at, snapshotted by `stopSession`.
/// Engine telemetry (`systemLegDelivered`, `feederVerdict`) must be read
/// BEFORE `engine.stop()`; `themUtteranceCount` AFTER the transcriber drain
/// (spec §3, "Evidence capture ordering").
struct SessionTypeEvidence: Sendable, Equatable {
    let requestedMode: RecordingMode
    /// API `meetingContext` / `suggestedFilename`, or an accepted MeetingDetector chip.
    let hasMeetingEvidence: Bool
    /// A *native* conferencing app (`ConferencingFamily` other than `.meetBrowser`)
    /// was frontmost at start. Browsers are excluded: Chrome frontmost during a
    /// phone-on-speaker call is the normal case, not call evidence.
    let nativeConferencingAppAtStart: Bool
    /// The "Them" leg bound and delivered at least one buffer
    /// (`systemFirstSampleTime != nil`). False = evidence UNAVAILABLE, not silent.
    let systemLegDelivered: Bool
    /// Device mode only; `.unfed` means the mix could not have carried a call.
    let feederVerdict: FeederVerdict?
    /// Final utterances attributed to "Them" with non-whitespace text.
    let themUtteranceCount: Int

    /// Defaults are the all-absent baseline (`.auto`, no signals, leg not
    /// delivered) so callers and tests can state only what they observed.
    init(
        requestedMode: RecordingMode = .auto,
        hasMeetingEvidence: Bool = false,
        nativeConferencingAppAtStart: Bool = false,
        systemLegDelivered: Bool = false,
        feederVerdict: FeederVerdict? = nil,
        themUtteranceCount: Int = 0
    ) {
        self.requestedMode = requestedMode
        self.hasMeetingEvidence = hasMeetingEvidence
        self.nativeConferencingAppAtStart = nativeConferencingAppAtStart
        self.systemLegDelivered = systemLegDelivered
        self.feederVerdict = feederVerdict
        self.themUtteranceCount = themUtteranceCount
    }
}

/// Why an `.auto` session resolved as a call. Raw values are the stable
/// `reasonLabel` tokens (logs + API status `resolution`).
enum CallReason: String, Sendable, Equatable {
    case meetingEvidence
    case conferencingApp
    case farEndSpeech
    case legUnavailable
}

/// Why an `.auto` session resolved as a voice memo. Raw values are the stable
/// `reasonLabel` tokens (logs + API status `resolution`).
enum MemoReason: String, Sendable, Equatable {
    case farEndSilent
    case mixUnfed
}

/// The resolver's verdict plus the rule that produced it.
enum SessionTypeResolution: Equatable, Sendable {
    /// The request named a type; evidence was not consulted.
    case explicit(SessionType)
    case call(reason: CallReason)
    case voiceMemo(reason: MemoReason)

    /// The resolved type every downstream consumer (handle, job, sidecar,
    /// notifications) sees.
    var sessionType: SessionType {
        switch self {
        case .explicit(let type): return type
        case .call: return .callCapture
        case .voiceMemo: return .voiceMemo
        }
    }

    /// Stable camelCase token for logs and the API status `resolution` field.
    /// Changing a token is an API break.
    var reasonLabel: String {
        switch self {
        case .explicit: return "explicit"
        case .call(let reason): return reason.rawValue
        case .voiceMemo(let reason): return reason.rawValue
        }
    }

    /// Whether the end-of-session "silent Them leg" note should be withheld.
    /// Only for a memo resolved *because* the live leg was silent — there the
    /// silence is the expected outcome, not a fault. Explicit calls and
    /// `.call(.meetingEvidence)` / `.call(.conferencingApp)` with a silent leg
    /// still get the note: that IS the "is my mix wired?" case (spec §7).
    var suppressesSilentLegNote: Bool {
        self == .voiceMemo(reason: .farEndSilent)
    }
}

/// Stop-time resolution of an `.auto` session's type. Pure — no engine access;
/// `ContentView.stopSession` assembles the evidence and calls this before
/// building the `SessionHandle`. Same house style as
/// `TranscriptionEngine.resolveSystemSource` and `FeederDetection.verdict`.
enum SessionTypeResolver {
    /// Precedence table from spec §3; first match wins. The order is the
    /// design: signals that positively identify a call outrank audio silence,
    /// and a leg that never delivered is MISSING evidence, never silence.
    static func resolveSessionType(_ e: SessionTypeEvidence) -> SessionTypeResolution {
        // Rule 1 — "Explicit intent (API callCapture/voiceMemo, ⌘⇧R,
        // Option-click) is never second-guessed."
        if let explicit = e.requestedMode.explicitSessionType {
            return .explicit(explicit)
        }

        // Rule 2 — "A named meeting is a meeting even if the far end never
        // spoke (user presented the whole time). Must outrank audio silence."
        if e.hasMeetingEvidence {
            return .call(reason: .meetingEvidence)
        }

        // Rule 3 — "Zoom/Teams/FaceTime/Slack/Webex frontmost at start. Zoom
        // exposes no topic, so rule 2 misses it. Browsers deliberately
        // excluded." (The exclusion is in how the caller builds the field.)
        if e.nativeConferencingAppAtStart {
            return .call(reason: .conferencingApp)
        }

        // Rule 4 — "The far end said something transcribable. Chosen over RMS:
        // a notification ding or hold music crosses audibleRMSThreshold but
        // does not transcribe."
        if e.themUtteranceCount >= 1 {
            return .call(reason: .farEndSpeech)
        }

        // Rule 5 — "The mixer wasn't running; the leg could not have carried a
        // call." A positive process-table fact, so it outranks rule 6's
        // missing-evidence fallback. Only `.unfed` counts: `.fed`, `.unknown`
        // and nil (SCK mode) carry no signal here.
        if case .unfed = e.feederVerdict {
            return .voiceMemo(reason: .mixUnfed)
        }

        // Rule 6 — "Unanswered ≠ silent (the 2026-07-27 lesson). A leg that
        // never bound (permission declined, SCK failure, wedged HAL) is
        // missing evidence, so fall back to the 95% base rate. The note is
        // already a call note; nothing to relocate."
        if !e.systemLegDelivered {
            return .call(reason: .legUnavailable)
        }

        // Rule 7 — "The leg was live and nobody on it ever said a word: phone
        // on speaker, in-person meeting, solo memo."
        return .voiceMemo(reason: .farEndSilent)
    }

    /// The spec §9 `.notice` line. Counts and flags only — the feeder verdict
    /// renders as a bare token (never the mixer name), never transcript text.
    static func logLine(for resolution: SessionTypeResolution, evidence e: SessionTypeEvidence) -> String {
        let feeder: String
        switch e.feederVerdict {
        case .none: feeder = "n/a"
        case .fed: feeder = "fed"
        case .unfed: feeder = "unfed"
        case .unknown: feeder = "unknown"
        }
        return "[STOP] session type resolved: \(resolution.sessionType.rawValue)"
            + " reason=\(resolution.reasonLabel)"
            + " them=\(e.themUtteranceCount)"
            + " legDelivered=\(e.systemLegDelivered)"
            + " feeder=\(feeder)"
            + " meeting=\(e.hasMeetingEvidence)"
            + " app=\(e.nativeConferencingAppAtStart)"
    }
}
