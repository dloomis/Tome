import Testing

@testable import Tome

// Truth table for the "Record this meeting?" reducer
// (docs/superpowers/specs/2026-10-06-record-this-meeting-prompt.md §2, "Tests").
// §2's evaluation order is the feature: steps 1/2 (recording → handled,
// post-stop suppression) are what keep this from nagging a user who just chose
// not to record, and unknown ≠ absent is a paid-for invariant. Each numbered
// test below is the spec's case of the same number.
//
// The harness models ContentView's 3 s idle poll: `t` is seconds since a fixed
// base instant, and every poll feeds the reducer exactly what the caller would
// (meeting nil while recording, `.absent` when no Teams window is found).

private let teams = DetectedMeeting(appName: "Teams", bundleID: "com.microsoft.teams2", title: "Weekly sync")
private let teamsRetitled = DetectedMeeting(appName: "Teams", bundleID: "com.microsoft.teams2", title: "Q4 planning")
private let zoom = DetectedMeeting(appName: "Zoom", bundleID: "us.zoom.xos", title: "Standup")

@Suite("Meeting join policy")
struct MeetingJoinPolicyTests {
    private struct Harness {
        var policy = MeetingJoinPolicy()
        let base = ContinuousClock.now
        var t = 0

        var now: ContinuousClock.Instant { base + .seconds(t) }

        /// One idle poll at absolute time `at` (seconds since base).
        @discardableResult
        mutating func poll(
            at: Int,
            _ meeting: DetectedMeeting? = teams,
            audio: CallAudioEvidence = .present
        ) -> MeetingJoinPolicy.Action {
            t = at
            return policy.step(.init(meeting: meeting, callAudio: audio, isRecording: false, now: now))
        }

        /// One poll while a session is recording (or pending) — the caller
        /// skips the scan, so meeting is nil.
        @discardableResult
        mutating func recordingPoll(at: Int) -> MeetingJoinPolicy.Action {
            t = at
            return policy.step(.init(meeting: nil, callAudio: .absent, isRecording: true, now: now))
        }

        /// Present polls every 3 s over `range`; returns every non-`.none` action.
        mutating func presentPolls(
            _ range: StrideThrough<Int>,
            _ meeting: DetectedMeeting = teams
        ) -> [MeetingJoinPolicy.Action] {
            range.map { poll(at: $0, meeting) }.filter { $0 != .none }
        }

        /// Drives a fresh instance to its prompt: present at 0, 3, 6, 9, 12.
        mutating func promptAt12() {
            for at in [0, 3, 6, 9] { _ = poll(at: at) }
            #expect(poll(at: 12) == .prompt(teams))
        }
    }

    @Test("1: present for 9 s does not prompt; the 12 s poll does")
    func sustainBeforePrompt() {
        var h = Harness()
        for at in [0, 3, 6, 9] {
            #expect(h.poll(at: at) == .none)
            #expect(h.policy.phase == .accumulating)
        }
        #expect(h.poll(at: 12) == .prompt(teams))
        #expect(h.policy.phase == .prompted)
        #expect(h.policy.isPromptAlive)
    }

    @Test("2: unknown neither resets nor advances the sustain")
    func unknownIsNotEvidence() {
        var h = Harness()
        #expect(h.poll(at: 0) == .none)
        #expect(h.poll(at: 3) == .none)
        #expect(h.poll(at: 6, audio: .unknown) == .none)
        #expect(h.poll(at: 9) == .none)
        // Not reset at 6: 12 - 0 ≥ 10.
        #expect(h.poll(at: 12) == .prompt(teams))

        // Not advanced: unknown before any presence starts nothing.
        var g = Harness()
        #expect(g.poll(at: 0, audio: .unknown) == .none)
        #expect(g.policy.phase == nil)
        for at in [3, 6, 9, 12] { #expect(g.poll(at: at) == .none) }
        #expect(g.poll(at: 15) == .prompt(teams))
    }

    @Test("3: an absent poll does not reset firstEvidence; prompt at 10 s from the first")
    func absentDoesNotReset() {
        var h = Harness()
        #expect(h.poll(at: 0) == .none)
        #expect(h.poll(at: 3, audio: .absent) == .none)
        #expect(h.policy.phase == .accumulating)
        #expect(h.poll(at: 6) == .none)
        #expect(h.poll(at: 9) == .none)
        #expect(h.poll(at: 12) == .prompt(teams))

        // A poll with no meeting at all is absent too.
        var g = Harness()
        #expect(g.poll(at: 0) == .none)
        #expect(g.poll(at: 3, nil, audio: .absent) == .none)
        #expect(g.poll(at: 10) == .prompt(teams))
    }

    @Test("4: recording withdraws a prompt and settles the instance for good")
    func recordingSettles() {
        var h = Harness()
        h.promptAt12()
        #expect(h.recordingPoll(at: 15) == .withdraw)
        #expect(h.policy.phase == .handled)
        #expect(!h.policy.isPromptAlive)
        #expect(h.recordingPoll(at: 18) == .none)
        // Stop; the call goes on well past the post-stop window.
        #expect(h.presentPolls(stride(from: 21, through: 900, by: 3)).isEmpty)
        #expect(h.policy.phase == .handled)
    }

    @Test("5: declined, presence continues → never asked again")
    func declineSettles() {
        var h = Harness()
        h.promptAt12()
        h.policy.userDeclined()
        #expect(h.policy.phase == .handled)
        #expect(!h.policy.isPromptAlive)
        #expect(h.presentPolls(stride(from: 15, through: 900, by: 3)).isEmpty)
    }

    @Test("6: presence within 30 s of a stop is born handled; 31 s+ prompts normally")
    func postStopSuppression() {
        // Within the window: the user stopped mid-call.
        var h = Harness()
        #expect(h.recordingPoll(at: 0) == .none)
        #expect(h.recordingPoll(at: 3) == .none)
        #expect(h.poll(at: 6) == .none)          // stop edge at 6 → suppressed until 36
        #expect(h.policy.phase == .handled)
        #expect(h.presentPolls(stride(from: 9, through: 600, by: 3)).isEmpty)

        // Last suppressed instant: 6 + 29.
        var e = Harness()
        e.recordingPoll(at: 0)
        e.poll(at: 6, nil, audio: .absent)       // stop edge at 6
        #expect(e.poll(at: 35) == .none)
        #expect(e.policy.phase == .handled)

        // After the window: first presence 31 s after the stop.
        var g = Harness()
        g.recordingPoll(at: 0)
        #expect(g.poll(at: 3, nil, audio: .absent) == .none)   // stop edge at 3
        #expect(g.poll(at: 34) == .none)
        #expect(g.policy.phase == .accumulating)
        #expect(g.poll(at: 40) == .none)
        #expect(g.poll(at: 44) == .prompt(teams))
    }

    @Test("7: absent 59 s keeps the instance; 60 s drops it; new presence is a new instance")
    func instanceGap() {
        var h = Harness()
        h.promptAt12()                                        // lastEvidence = 12
        #expect(h.poll(at: 40, audio: .absent) == .none)
        #expect(h.poll(at: 71, audio: .absent) == .none)      // 59 s
        #expect(h.policy.phase == .prompted)
        #expect(h.poll(at: 72, audio: .absent) == .withdraw)  // 60 s
        #expect(h.policy.phase == nil)
        #expect(h.poll(at: 75, audio: .absent) == .none)      // withdraw not repeated
        #expect(h.poll(at: 78) == .none)
        #expect(h.policy.phase == .accumulating)
        #expect(h.poll(at: 84) == .none)
        #expect(h.poll(at: 88) == .prompt(teams))

        // An accumulating instance drops silently.
        var g = Harness()
        g.poll(at: 0)
        #expect(g.poll(at: 60, nil, audio: .absent) == .none)
        #expect(g.policy.phase == nil)
    }

    @Test("8: an hour of recording keeps the instance alive")
    func recordingKeepsInstanceAlive() {
        var h = Harness()
        #expect(h.poll(at: 0) == .none)
        for at in stride(from: 3, through: 3603, by: 3) {
            #expect(h.recordingPoll(at: at) == .none)
        }
        #expect(h.policy.phase == .handled)
        // Stop while the call is still live: same instance, no fresh prompt.
        #expect(h.presentPolls(stride(from: 3606, through: 4200, by: 3)).isEmpty)
        #expect(h.policy.phase == .handled)
    }

    @Test("9: a bundle-ID change replaces the instance and withdraws its prompt")
    func bundleChangeReplaces() {
        var h = Harness()
        h.promptAt12()
        #expect(h.poll(at: 15, zoom) == .withdraw)
        #expect(h.policy.phase == .accumulating)
        #expect(!h.policy.isPromptAlive)
        #expect(h.poll(at: 21, zoom) == .none)
        #expect(h.poll(at: 25, zoom) == .prompt(zoom))

        // Replacing an unprompted instance is silent.
        var g = Harness()
        g.poll(at: 0)
        #expect(g.poll(at: 3, zoom) == .none)
        #expect(g.poll(at: 12, zoom) == .none)   // sustain restarted at 3
        #expect(g.poll(at: 13, zoom) == .prompt(zoom))
    }

    @Test("10: a title change with the same bundle ID is the same instance")
    func retitleSameInstance() {
        var h = Harness()
        #expect(h.poll(at: 0) == .none)
        #expect(h.poll(at: 6, teamsRetitled) == .none)
        // Sustain still runs from 0; the prompt carries the latest title.
        #expect(h.poll(at: 12, teamsRetitled) == .prompt(teamsRetitled))
        #expect(h.poll(at: 15) == .none)
        #expect(h.presentPolls(stride(from: 18, through: 600, by: 3), teamsRetitled).isEmpty)
        #expect(h.policy.phase == .prompted)
    }

    @Test("11: accepted settles the instance; .withdraw is never emitted twice")
    func acceptedNoDoubleWithdraw() {
        var h = Harness()
        h.promptAt12()
        h.policy.userAccepted()
        #expect(h.policy.phase == .handled)
        #expect(!h.policy.isPromptAlive)
        // The caller already tore its surfaces down; the start lands next tick.
        #expect(h.recordingPoll(at: 15) == .none)
        #expect(h.recordingPoll(at: 18) == .none)
        #expect(h.presentPolls(stride(from: 21, through: 300, by: 3)).isEmpty)
        // Call ends: expiry of a handled instance is silent too.
        #expect(h.poll(at: 360, nil, audio: .absent) == .none)
        #expect(h.policy.phase == nil)

        // Without an accept, recording withdraws exactly once.
        var g = Harness()
        g.promptAt12()
        #expect(g.recordingPoll(at: 15) == .withdraw)
        #expect(g.recordingPoll(at: 18) == .none)
        #expect(g.poll(at: 21) == .none)
    }

    @Test("12: isPromptAlive is false once the instance expires")
    func staleNotificationGuard() {
        var h = Harness()
        #expect(!h.policy.isPromptAlive)
        h.promptAt12()
        #expect(h.policy.isPromptAlive)
        #expect(h.poll(at: 50, nil, audio: .absent) == .none)
        #expect(h.policy.isPromptAlive)
        #expect(h.poll(at: 72, nil, audio: .absent) == .withdraw)
        #expect(!h.policy.isPromptAlive)
        // A late Record/Decline on the dead instance changes nothing.
        h.policy.userAccepted()
        h.policy.userDeclined()
        #expect(h.policy.phase == nil)
    }

    // Expiry is checked on every idle poll, not only absent ones — the
    // sleep/wake edge case ("an instance left over from yesterday expires on
    // the first tick") and §2's "sixty seconds of unanswered queries end it".

    @Test("Expiry: a present poll after a ≥60 s gap is a new call that must sustain again")
    func presentAfterGapIsNewInstance() {
        // Accumulating instance, Mac sleeps: no instant prompt at wake.
        var h = Harness()
        h.poll(at: 0)
        #expect(h.poll(at: 3600) == .none)
        #expect(h.policy.phase == .accumulating)
        #expect(h.poll(at: 3609) == .none)
        #expect(h.poll(at: 3610) == .prompt(teams))

        // Handled instance from the previous call does not swallow the next one.
        var g = Harness()
        g.promptAt12()
        g.policy.userDeclined()
        #expect(g.poll(at: 3600) == .none)
        #expect(g.policy.phase == .accumulating)
        #expect(g.poll(at: 3610) == .prompt(teams))

        // A prompted instance across the gap is withdrawn, then starts over.
        var p = Harness()
        p.promptAt12()
        #expect(p.poll(at: 3600) == .withdraw)
        #expect(p.policy.phase == .accumulating)
    }

    @Test("Expiry: sixty seconds of unanswered queries end the instance")
    func unknownAgesToExpiry() {
        var h = Harness()
        h.promptAt12()
        #expect(h.poll(at: 45, audio: .unknown) == .none)
        #expect(h.policy.isPromptAlive)
        #expect(h.poll(at: 72, audio: .unknown) == .withdraw)
        #expect(h.policy.phase == nil)
        // Unknown after expiry creates nothing.
        #expect(h.poll(at: 75, audio: .unknown) == .none)
        #expect(h.policy.phase == nil)
    }
}

@Suite("Call audio evidence matcher")
struct CallAudioEvidenceMatchTests {
    private func evidence(_ result: HALQueryResult<Set<String>?>) -> CallAudioEvidence {
        MeetingJoinPolicy.callAudioEvidence(for: "com.microsoft.teams2", from: result)
    }

    @Test("Exact bundle ID is present")
    func exact() {
        #expect(evidence(.answered(["com.apple.Music", "com.microsoft.teams2"])) == .present)
    }

    @Test("Dotted sub-identifier is present")
    func dottedPrefix() {
        #expect(evidence(.answered(["com.microsoft.teams2.modulehost"])) == .present)
    }

    @Test("Undotted string prefix is not a match")
    func undottedPrefix() {
        #expect(evidence(.answered(["com.microsoft.teams2helper"])) == .absent)
        // Nor is the legacy app's ID a match for teams2 (or vice versa).
        #expect(evidence(.answered(["com.microsoft.teams"])) == .absent)
        #expect(MeetingJoinPolicy.callAudioEvidence(
            for: "com.microsoft.teams", from: .answered(["com.microsoft.teams2"])) == .absent)
    }

    @Test("Unanswered HAL query is unknown, not absent")
    func unavailable() {
        #expect(evidence(.unavailable) == .unknown)
    }

    @Test("Failed process-list read is unknown, not absent")
    func failedRead() {
        #expect(evidence(.answered(nil)) == .unknown)
    }

    @Test("Answered empty set is absent")
    func emptySet() {
        #expect(evidence(.answered([])) == .absent)
    }
}

@Suite("Conferencing app table")
struct ConferencingAppTableTests {
    @Test("Exactly the two Teams entries prompt to record (spec §7)")
    func onlyTeamsPrompts() {
        let prompting = Set(conferencingApps.filter { $0.value.promptsToRecord }.keys)
        #expect(prompting == ["com.microsoft.teams2", "com.microsoft.teams"])
    }
}
