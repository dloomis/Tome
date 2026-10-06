import Foundation

/// The audio half of one poll's in-call evidence (spec §1): is the detected
/// meeting's app running audio *output* right now?
///
/// Three-valued on purpose. **Unknown ≠ absent**: a HAL query that went
/// unanswered, or a process-list read that failed, is no evidence either way —
/// it must neither advance nor reset the sustain clock. Same discipline as the
/// failsafe's shadow probe and `TranscriptionEngine.resolveMicTarget`.
enum CallAudioEvidence: Sendable, Equatable {
    case present
    case absent
    case unknown
}

/// The idle "Record this meeting?" prompt, as a pure reducer.
///
/// A meeting-titled Teams window alone also matches the lobby, a popped-out
/// chat and the recap window; Teams running audio output alone also matches a
/// chime or a ringtone. Both together, sustained for `sustainSeconds`, is what a
/// joined call looks like — so that is when the caller is told to ask. Nothing
/// here (or anywhere) starts a recording: the only outputs are "ask" and
/// "stop asking".
///
/// No clocks, HAL or AppKit: the caller (ContentView's 3 s idle meeting-detection
/// loop) steps it once per poll with an `Observation` and acts on the returned
/// `Action`. The evaluation order in `step` is the specification — see §2 of
/// `docs/superpowers/specs/2026-10-06-record-this-meeting-prompt.md`. Every
/// ambiguity is resolved in the direction of *not* nagging someone mid-call:
/// one instance per call, no re-prompt, no snooze.
struct MeetingJoinPolicy: Sendable {
    /// Both evidence halves must span this long (wall-clock from the first
    /// present poll) before a prompt. Filters chimes and gives WhisperCal's
    /// calendar `/start` a head start, so the common case never prompts.
    static let sustainSeconds: Duration = .seconds(10)
    /// No present evidence for this long ends the instance: the call is over,
    /// and the next one is a new question.
    static let instanceGapSeconds: Duration = .seconds(60)
    /// After a recording stops, new instances are born `handled` for this long —
    /// the user who stopped mid-call must not be asked to record it again.
    static let postStopSuppressSeconds: Duration = .seconds(30)
    /// The caller's panel auto-hides after this long and reports `userDeclined`.
    /// The policy itself never times a prompt out.
    static let unansweredTimeout: Duration = .seconds(60)

    struct Observation: Sendable {
        /// The scan's meeting; nil when none was found or the scan was skipped.
        var meeting: DetectedMeeting?
        /// §1's audio half. The caller passes `.absent` for an app whose
        /// `promptsToRecord` is false — the policy does not consult the table.
        var callAudio: CallAudioEvidence
        /// `isLiveRecordingSession || services.isSessionPending`.
        var isRecording: Bool
        var now: ContinuousClock.Instant
    }

    enum Action: Equatable, Sendable {
        case none
        /// Show the panel + notification for this meeting (latest title).
        case prompt(DetectedMeeting)
        /// Tear down whatever prompt is up.
        case withdraw
    }

    enum Phase: Equatable, Sendable {
        /// Evidence seen, sustain not yet reached.
        case accumulating
        /// A prompt is up (or was, until the caller reports an answer).
        case prompted
        /// Settled for the rest of this call: answered, recorded, or born
        /// inside the post-stop suppression window.
        case handled
    }

    /// One call. Keyed by **bundle ID only**: a mid-call retitle (screen share,
    /// "Meeting with …" → subject) is the same call and must not re-prompt.
    private struct Instance: Sendable {
        let bundleID: String
        /// The latest meeting seen, so `.prompt` carries the current title.
        var meeting: DetectedMeeting
        /// Sustain is measured from here. Never reset by an absent or unknown
        /// poll — only a full `instanceGapSeconds` lapse ends the instance.
        let firstEvidence: ContinuousClock.Instant
        var lastEvidence: ContinuousClock.Instant
        var phase: Phase
    }

    private var instance: Instance?
    private var suppressNewInstancesUntil: ContinuousClock.Instant?
    private var wasRecording = false

    init() {}

    /// The current instance's phase, nil when there is none.
    var phase: Phase? { instance?.phase }

    /// True iff a prompt is currently up for a live instance. The stale-
    /// notification guard: Record from a notification whose call has ended
    /// must not start an empty recording.
    var isPromptAlive: Bool { instance?.phase == .prompted }

    /// Called once per poll. Order is binding (spec §2).
    mutating func step(_ o: Observation) -> Action {
        let now = o.now

        // 1. Recording. The instance (if any) is settled and kept alive — a
        //    one-hour recording of a one-hour call must not end in a fresh
        //    instance that prompts at stop. Nothing below runs while recording:
        //    no instance is created, no prompt can be raised.
        if o.isRecording {
            wasRecording = true
            guard var current = instance else { return .none }
            let wasPrompted = current.phase == .prompted
            current.phase = .handled
            current.lastEvidence = now
            instance = current
            return wasPrompted ? .withdraw : .none
        }

        // 2. Stop edge. The user who just stopped mid-call (a sensitive
        //    stretch, a wrong-meeting start) must not be asked "Record this
        //    meeting?" ten seconds later.
        if wasRecording {
            wasRecording = false
            suppressNewInstancesUntil = now + Self.postStopSuppressSeconds
        }

        // 3. Expiry (spec step 5's gap check, hoisted so it also applies to
        //    present and unknown polls). An instance whose last evidence is
        //    `instanceGapSeconds` old is over whatever this poll says: after a
        //    sleep, a present poll is a NEW call that must sustain its own
        //    10 s (and must not inherit a `handled` from yesterday), and sixty
        //    seconds of unanswered queries end the instance as §2 intends.
        var droppedPrompt = false
        if let current = instance, now - current.lastEvidence >= Self.instanceGapSeconds {
            droppedPrompt = current.phase == .prompted
            instance = nil
        }

        // 4. Evidence. Unknown neither advances nor resets anything.
        guard let meeting = o.meeting else {
            return droppedPrompt ? .withdraw : .none
        }
        switch o.callAudio {
        case .unknown, .absent:
            // Absent ages the instance toward step 3's expiry; unknown is not
            // even that — but time passes either way.
            return droppedPrompt ? .withdraw : .none
        case .present:
            break
        }

        // 5. Present.
        guard var current = instance, current.bundleID == meeting.bundleID else {
            // New call, or the app switched: a fresh instance. Born settled
            // inside the post-stop window.
            let replacedPrompt = instance?.phase == .prompted
            let suppressed = suppressNewInstancesUntil.map { now < $0 } ?? false
            instance = Instance(
                bundleID: meeting.bundleID,
                meeting: meeting,
                firstEvidence: now,
                lastEvidence: now,
                phase: suppressed ? .handled : .accumulating
            )
            return (droppedPrompt || replacedPrompt) ? .withdraw : .none
        }
        current.lastEvidence = now
        current.meeting = meeting
        if current.phase == .accumulating, now - current.firstEvidence >= Self.sustainSeconds {
            current.phase = .prompted
            instance = current
            return .prompt(meeting)
        }
        instance = current
        return .none
    }

    /// Record pressed on either surface. The caller withdraws its own surfaces;
    /// the instance is settled so no `.withdraw` follows for it.
    mutating func userAccepted() {
        instance?.phase = .handled
    }

    /// Not This Meeting, the panel's ✕, the panel timing out, or the prompt
    /// dropped because the setting is off / no model is provisioned. No snooze:
    /// the instance ends when the call ends.
    mutating func userDeclined() {
        instance?.phase = .handled
    }

    /// §1's audio half from the `.query`-lane process-list read. A process
    /// matches the app on an exact bundle ID or a dotted sub-identifier
    /// (`com.microsoft.teams2.modulehost`) — never a bare string prefix
    /// (`com.microsoft.teams2helper` is a different app).
    static func callAudioEvidence(
        for appBundleID: String,
        from result: HALQueryResult<Set<String>?>
    ) -> CallAudioEvidence {
        guard case .answered(let answer) = result, let bundleIDs = answer else {
            // Unanswered query or failed read: no information, not "absent".
            return .unknown
        }
        let subPrefix = appBundleID + "."
        let matched = bundleIDs.contains { $0 == appBundleID || $0.hasPrefix(subPrefix) }
        return matched ? .present : .absent
    }
}
