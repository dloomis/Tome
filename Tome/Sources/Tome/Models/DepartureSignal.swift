import Foundation

/// Evidence that the user's physical or session context changed mid-recording —
/// undocked, audio route moved, screen locked, Mac slept. A departure signal
/// never stops a recording by itself: it latches in `AutoStopPolicy`, where it
/// shortens the silence window and turns the outcome from a question into a
/// countdown. Spec: `docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md`.
enum DepartureSignal: String, Sendable, Equatable, CaseIterable {
    case wokeFromSleep
    case displayRemoved
    case audioDeviceRemoved
    case micRouteChanged
    case outputRouteChanged
    case callSourceLost
    case screenLocked

    /// Sentence-leading clause shared by the countdown and the post-stop notice.
    var userPhrase: String {
        switch self {
        case .wokeFromSleep: "Your Mac woke from sleep"
        case .displayRemoved: "A display was disconnected"
        case .audioDeviceRemoved: "An audio device was disconnected"
        case .micRouteChanged: "The microphone changed"
        case .outputRouteChanged: "The audio output changed"
        case .callSourceLost: "The call audio device was disconnected"
        case .screenLocked: "The screen was locked"
        }
    }
}

/// Why the failsafe ended (or is about to end) a session.
enum AutoStopReason: Sendable, Equatable {
    /// R1 — the Mac was asleep for `seconds` with the session live.
    case slept(seconds: Int)
    /// R2 — a departure signal plus trusted silence.
    case departure(DepartureSignal)
    /// R3 — the silence prompt went unanswered.
    case unansweredSilence

    /// Metadata-only label for `[AUTOSTOP]` log lines.
    var logLabel: String {
        switch self {
        case .slept: "slept"
        case .departure(let signal): "departure.\(signal.rawValue)"
        case .unansweredSilence: "unansweredSilence"
        }
    }

    /// One line for the countdown surfaces (panel, ControlBar row, notification).
    /// `farEndOnly` mirrors `SilenceSignal`: true once the far end has been
    /// heard, when only call audio is being judged.
    func countdownLine(farEndOnly: Bool) -> String {
        switch self {
        case .slept:
            "Your Mac was asleep"
        case .departure(let signal):
            "\(signal.userPhrase) and \(farEndOnly ? "the call is silent" : "it's silent")"
        case .unansweredSilence:
            "\(farEndOnly ? "No call audio" : "Silence") and the stop prompt went unanswered"
        }
    }

    /// Full sentence for the post-stop notice.
    func stoppedDetail(silenceSeconds: Int, farEndOnly: Bool) -> String {
        switch self {
        case .slept(let seconds):
            "Your Mac was asleep for \(Self.duration(seconds)), so the recording was ended and saved."
        case .departure(let signal):
            "\(signal.userPhrase) and \(farEndOnly ? "the call" : "the recording") had been silent for \(Self.duration(silenceSeconds)). The recording was saved."
        case .unansweredSilence:
            "No \(farEndOnly ? "call audio" : "audio") for \(Self.duration(silenceSeconds)) and the stop prompt went unanswered. The recording was saved."
        }
    }

    static func duration(_ seconds: Int) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds < 90 { return plural(max(seconds, 0), "second") }
        if seconds < 90 * 60 { return plural(Int((Double(seconds) / 60).rounded()), "minute") }
        return plural(Int((Double(seconds) / 3600).rounded()), "hour")
    }
}
