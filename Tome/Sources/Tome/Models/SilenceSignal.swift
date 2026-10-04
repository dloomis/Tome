/// Which audio counts as "not silent" for the silence stop-confirmation.
///
/// Once the far end ("Them" leg) has been heard in a session, only that leg
/// keeps the session alive: after a call ends the user is usually still at
/// the desk, and room noise or typing on the mic would otherwise reset the
/// silence window forever. Until the far end has been heard — voice memos,
/// in-person meetings, a pre-join call, a "Them" leg that never delivered —
/// the mic counts too, so an unavailable leg is never mistaken for silence.
enum SilenceSignal {
    /// Level above which a leg counts as audible (same scale as the UI meter).
    static let audibleLevel: Float = 0.01

    /// The level the silence timer should judge. `combined` is the mic + far-end
    /// meter level; `farEnd` is the "Them" leg alone.
    static func level(combined: Float, farEnd: Float, farEndHeard: Bool) -> Float {
        farEndHeard ? farEnd : combined
    }

    /// Whether a finalized utterance is evidence against silence.
    static func utteranceBreaksSilence(_ speaker: Speaker, farEndHeard: Bool) -> Bool {
        !farEndHeard || speaker == .them
    }
}
