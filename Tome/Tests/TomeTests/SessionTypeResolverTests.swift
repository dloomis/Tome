import Testing

@testable import Tome

// Tests for the single-record-button stop-time resolver
// (docs/superpowers/specs/2026-09-26-single-record-button-auto-mode.md §1, §3).
//
// The precedence table encodes the codebase's twice-learned rule: a leg that
// never delivered (permission declined, SCK failure, wedged HAL) is MISSING
// evidence, not evidence of silence — it falls back to the 95% call base rate
// and must never be read as "nobody on the far end spoke".
//
// "Browser frontmost never contributes" (spec Tests §1) is enforced by the
// CALLER that builds `nativeConferencingAppAtStart`: that field is defined as
// a native `ConferencingFamily` other than `.meetBrowser`, so a frontmost
// Chrome/Safari/Arc never sets it. The resolver cannot see which app was
// frontmost and so has nothing to test here; the stopSession evidence
// builder's tests own that guarantee.

@Suite("Session type resolver")
struct SessionTypeResolverTests {
    /// Baseline: `.auto`, every signal absent/false/zero, leg NOT delivered.
    /// Tests override one field at a time from here.
    private func evidence(
        requestedMode: RecordingMode = .auto,
        hasMeetingEvidence: Bool = false,
        nativeConferencingAppAtStart: Bool = false,
        systemLegDelivered: Bool = false,
        feederVerdict: FeederVerdict? = nil,
        themUtteranceCount: Int = 0
    ) -> SessionTypeEvidence {
        SessionTypeEvidence(
            requestedMode: requestedMode,
            hasMeetingEvidence: hasMeetingEvidence,
            nativeConferencingAppAtStart: nativeConferencingAppAtStart,
            systemLegDelivered: systemLegDelivered,
            feederVerdict: feederVerdict,
            themUtteranceCount: themUtteranceCount
        )
    }

    private func resolve(_ e: SessionTypeEvidence) -> SessionTypeResolution {
        SessionTypeResolver.resolveSessionType(e)
    }

    // MARK: - Evidence defaults

    @Test func evidenceInitDefaultsAreTheAllAbsentBaseline() {
        let e = SessionTypeEvidence()
        #expect(e.requestedMode == .auto)
        #expect(e.hasMeetingEvidence == false)
        #expect(e.nativeConferencingAppAtStart == false)
        #expect(e.systemLegDelivered == false)
        #expect(e.feederVerdict == nil)
        #expect(e.themUtteranceCount == 0)
        #expect(e == evidence())
    }

    // MARK: - Rule 1: explicit mode is never second-guessed

    @Test func explicitCallCaptureIgnoresMemoShapedEvidence() {
        // Everything screams "phone on speaker": live leg, silent far end,
        // even an unfed mix. Explicit intent still wins.
        let e = evidence(
            requestedMode: .callCapture,
            systemLegDelivered: true,
            feederVerdict: .unfed(mixerName: "Wave Link"),
            themUtteranceCount: 0
        )
        #expect(resolve(e) == .explicit(.callCapture))
    }

    @Test func explicitVoiceMemoIgnoresCallShapedEvidence() {
        // ⌘⇧R during a Zoom call: the far end is lost, by design — the
        // escape hatch is never overridden.
        let e = evidence(
            requestedMode: .voiceMemo,
            hasMeetingEvidence: true,
            nativeConferencingAppAtStart: true,
            systemLegDelivered: true,
            feederVerdict: .fed,
            themUtteranceCount: 42
        )
        #expect(resolve(e) == .explicit(.voiceMemo))
    }

    @Test func explicitModesIgnoreTheBaselineToo() {
        #expect(resolve(evidence(requestedMode: .callCapture)) == .explicit(.callCapture))
        #expect(resolve(evidence(requestedMode: .voiceMemo)) == .explicit(.voiceMemo))
    }

    @Test(arguments: [RecordingMode.callCapture, .voiceMemo])
    func explicitModeIgnoresEveryFieldCombination(mode: RecordingMode) {
        // Exhaustive over the boolean fields and every verdict shape: no
        // combination moves an explicit request off its own type.
        let verdicts: [FeederVerdict?] = [nil, .fed, .unknown, .unfed(mixerName: "Wave Link")]
        for meeting in [false, true] {
            for app in [false, true] {
                for leg in [false, true] {
                    for verdict in verdicts {
                        for them in [0, 1, 7] {
                            let e = evidence(
                                requestedMode: mode,
                                hasMeetingEvidence: meeting,
                                nativeConferencingAppAtStart: app,
                                systemLegDelivered: leg,
                                feederVerdict: verdict,
                                themUtteranceCount: them
                            )
                            #expect(resolve(e) == .explicit(mode.explicitSessionType!))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rule 2: meeting evidence

    @Test func meetingEvidenceFiresAlone() {
        #expect(resolve(evidence(hasMeetingEvidence: true)) == .call(reason: .meetingEvidence))
    }

    @Test func meetingEvidenceOutranksSilentLiveLeg() {
        // The WhisperCal meeting where only the user presented: leg live,
        // far end never spoke. Rule 7 would say memo; rule 2 must win.
        let e = evidence(hasMeetingEvidence: true, systemLegDelivered: true, themUtteranceCount: 0)
        #expect(resolve(e) == .call(reason: .meetingEvidence))
    }

    @Test func meetingEvidenceOutranksUnfedMix() {
        let e = evidence(
            hasMeetingEvidence: true,
            systemLegDelivered: true,
            feederVerdict: .unfed(mixerName: "Wave Link")
        )
        #expect(resolve(e) == .call(reason: .meetingEvidence))
    }

    @Test func meetingEvidenceOutranksLowerCallRules() {
        // Reason attribution: the highest-precedence rule names the reason.
        let e = evidence(
            hasMeetingEvidence: true,
            nativeConferencingAppAtStart: true,
            systemLegDelivered: true,
            themUtteranceCount: 3
        )
        #expect(resolve(e) == .call(reason: .meetingEvidence))
    }

    // MARK: - Rule 3: native conferencing app frontmost at start

    @Test func conferencingAppFiresAlone() {
        #expect(resolve(evidence(nativeConferencingAppAtStart: true)) == .call(reason: .conferencingApp))
    }

    @Test func conferencingAppOutranksSilentLiveLeg() {
        // Zoom call, the user talked the whole time, Zoom exposes no topic.
        let e = evidence(nativeConferencingAppAtStart: true, systemLegDelivered: true, themUtteranceCount: 0)
        #expect(resolve(e) == .call(reason: .conferencingApp))
    }

    @Test func conferencingAppOutranksUnfedMix() {
        let e = evidence(
            nativeConferencingAppAtStart: true,
            systemLegDelivered: true,
            feederVerdict: .unfed(mixerName: "Wave Link")
        )
        #expect(resolve(e) == .call(reason: .conferencingApp))
    }

    @Test func conferencingAppOutranksFarEndSpeech() {
        let e = evidence(nativeConferencingAppAtStart: true, systemLegDelivered: true, themUtteranceCount: 5)
        #expect(resolve(e) == .call(reason: .conferencingApp))
    }

    // MARK: - Rule 4: far-end speech

    @Test func farEndSpeechFiresOnOneUtterance() {
        // The proposed bar is exactly one transcribable "Them" utterance.
        let e = evidence(systemLegDelivered: true, themUtteranceCount: 1)
        #expect(resolve(e) == .call(reason: .farEndSpeech))
    }

    @Test func farEndSpeechOutranksUnfedMix() {
        // If the far end actually transcribed, the leg evidently carried
        // audio — a stale/odd verdict can't turn that into a memo.
        let e = evidence(
            systemLegDelivered: true,
            feederVerdict: .unfed(mixerName: "Wave Link"),
            themUtteranceCount: 2
        )
        #expect(resolve(e) == .call(reason: .farEndSpeech))
    }

    @Test func farEndSpeechOutranksUndeliveredLeg() {
        // Utterances counted from the store are direct evidence; the
        // delivery flag is irrelevant once there's speech.
        let e = evidence(systemLegDelivered: false, themUtteranceCount: 1)
        #expect(resolve(e) == .call(reason: .farEndSpeech))
    }

    @Test func negativeThemCountIsNotSpeech() {
        // Defensive: a nonsensical negative count is not far-end speech.
        let e = evidence(systemLegDelivered: true, themUtteranceCount: -1)
        #expect(resolve(e) == .voiceMemo(reason: .farEndSilent))
    }

    // MARK: - Rule 5: unfed mix

    @Test func unfedMixFiresWithLiveLeg() {
        // Device mode, Wave Link closed: the device still binds and delivers
        // exact zeros. It could not have carried a call.
        let e = evidence(systemLegDelivered: true, feederVerdict: .unfed(mixerName: "Wave Link"))
        #expect(resolve(e) == .voiceMemo(reason: .mixUnfed))
    }

    @Test func unfedMixOutranksUndeliveredLeg() {
        // Rule 5 outranks rule 6: the process table positively says nothing
        // could feed the leg — that is evidence, unlike a missing delivery.
        let e = evidence(systemLegDelivered: false, feederVerdict: .unfed(mixerName: "Wave Link"))
        #expect(resolve(e) == .voiceMemo(reason: .mixUnfed))
    }

    @Test func unfedMixIgnoresMixerName() {
        let e = evidence(systemLegDelivered: true, feederVerdict: .unfed(mixerName: "Some Other Mixer"))
        #expect(resolve(e) == .voiceMemo(reason: .mixUnfed))
    }

    // MARK: - Rule 6: leg unavailable (unanswered ≠ silent)

    @Test func undeliveredLegWithNoOtherEvidenceIsCallNeverMemo() {
        // The 2026-07-27 lesson: a leg that never delivered a buffer is
        // missing evidence. Zero "Them" utterances from a leg that never ran
        // says nothing about the far end — fall back to the call base rate.
        let resolution = resolve(evidence(systemLegDelivered: false, themUtteranceCount: 0))
        #expect(resolution == .call(reason: .legUnavailable))
        #expect(resolution.sessionType == .callCapture)
    }

    @Test(arguments: [FeederVerdict?.none, .some(.fed), .some(.unknown)])
    func undeliveredLegIsCallForEveryNonUnfedVerdict(verdict: FeederVerdict?) {
        let e = evidence(systemLegDelivered: false, feederVerdict: verdict)
        #expect(resolve(e) == .call(reason: .legUnavailable))
    }

    // MARK: - Rule 7: live leg, silent far end

    @Test func liveSilentLegWithNoOtherEvidenceIsMemo() {
        // The target case: phone on speaker, Chrome frontmost, no calendar
        // event. The leg was live and nobody on it said a word.
        let resolution = resolve(evidence(systemLegDelivered: true, themUtteranceCount: 0))
        #expect(resolution == .voiceMemo(reason: .farEndSilent))
        #expect(resolution.sessionType == .voiceMemo)
    }

    // MARK: - Feeder verdict: only `.unfed` is evidence

    @Test(arguments: [FeederVerdict?.none, .some(.fed), .some(.unknown)])
    func nonUnfedVerdictsBehaveIdenticallyAcrossTheTable(verdict: FeederVerdict?) {
        // `.fed`, `.unknown` and nil (SCK mode) carry no resolution signal:
        // for every other-field combination they resolve exactly as nil does.
        for meeting in [false, true] {
            for app in [false, true] {
                for leg in [false, true] {
                    for them in [0, 1] {
                        let withVerdict = evidence(
                            hasMeetingEvidence: meeting,
                            nativeConferencingAppAtStart: app,
                            systemLegDelivered: leg,
                            feederVerdict: verdict,
                            themUtteranceCount: them
                        )
                        let withNil = evidence(
                            hasMeetingEvidence: meeting,
                            nativeConferencingAppAtStart: app,
                            systemLegDelivered: leg,
                            feederVerdict: nil,
                            themUtteranceCount: them
                        )
                        #expect(resolve(withVerdict) == resolve(withNil))
                    }
                }
            }
        }
    }

    @Test(arguments: [FeederVerdict?.none, .some(.fed), .some(.unknown)])
    func fedUnknownAndNilAllResolveSilentLiveLegAsMemo(verdict: FeederVerdict?) {
        // A fed-but-quiet mix is zeros-as-content, never a fault and never
        // a reason to call it a meeting.
        let e = evidence(systemLegDelivered: true, feederVerdict: verdict)
        #expect(resolve(e) == .voiceMemo(reason: .farEndSilent))
    }

    // MARK: - Full truth table (auto mode)

    @Test func fullAutoTruthTableMatchesPrecedence() {
        // Independent oracle for the seven-rule table, enumerated over every
        // combination of the auto-mode inputs.
        let verdicts: [FeederVerdict?] = [nil, .fed, .unknown, .unfed(mixerName: "Wave Link")]
        var count = 0
        for meeting in [false, true] {
            for app in [false, true] {
                for leg in [false, true] {
                    for verdict in verdicts {
                        for them in [0, 1, 3] {
                            let e = evidence(
                                hasMeetingEvidence: meeting,
                                nativeConferencingAppAtStart: app,
                                systemLegDelivered: leg,
                                feederVerdict: verdict,
                                themUtteranceCount: them
                            )
                            let isUnfed: Bool
                            if case .unfed = verdict { isUnfed = true } else { isUnfed = false }
                            let expected: SessionTypeResolution =
                                meeting ? .call(reason: .meetingEvidence)
                                : app ? .call(reason: .conferencingApp)
                                : them >= 1 ? .call(reason: .farEndSpeech)
                                : isUnfed ? .voiceMemo(reason: .mixUnfed)
                                : !leg ? .call(reason: .legUnavailable)
                                : .voiceMemo(reason: .farEndSilent)
                            #expect(resolve(e) == expected)
                            count += 1
                        }
                    }
                }
            }
        }
        #expect(count == 2 * 2 * 2 * 4 * 3)
    }

    // MARK: - Resolution accessors

    @Test func sessionTypeForEveryCase() {
        #expect(SessionTypeResolution.explicit(.callCapture).sessionType == .callCapture)
        #expect(SessionTypeResolution.explicit(.voiceMemo).sessionType == .voiceMemo)
        for reason in [CallReason.meetingEvidence, .conferencingApp, .farEndSpeech, .legUnavailable] {
            #expect(SessionTypeResolution.call(reason: reason).sessionType == .callCapture)
        }
        for reason in [MemoReason.farEndSilent, .mixUnfed] {
            #expect(SessionTypeResolution.voiceMemo(reason: reason).sessionType == .voiceMemo)
        }
    }

    @Test func reasonLabelForEveryCase() {
        // Stable tokens: logged and exposed in the API status `resolution`
        // field. Changing one is an API break.
        #expect(SessionTypeResolution.explicit(.callCapture).reasonLabel == "explicit")
        #expect(SessionTypeResolution.explicit(.voiceMemo).reasonLabel == "explicit")
        #expect(SessionTypeResolution.call(reason: .meetingEvidence).reasonLabel == "meetingEvidence")
        #expect(SessionTypeResolution.call(reason: .conferencingApp).reasonLabel == "conferencingApp")
        #expect(SessionTypeResolution.call(reason: .farEndSpeech).reasonLabel == "farEndSpeech")
        #expect(SessionTypeResolution.call(reason: .legUnavailable).reasonLabel == "legUnavailable")
        #expect(SessionTypeResolution.voiceMemo(reason: .farEndSilent).reasonLabel == "farEndSilent")
        #expect(SessionTypeResolution.voiceMemo(reason: .mixUnfed).reasonLabel == "mixUnfed")
    }

    @Test func suppressesSilentLegNoteOnlyForFarEndSilentMemo() {
        // Spec §7: a memo whose system leg was silent is the expected outcome.
        // Every call — explicit, meeting evidence, conferencing app — with a
        // silent leg still gets the "is my mix wired?" note. An unfed-mix
        // memo already got the bind-time unfed warning; suppression is
        // reserved for the one case where silence is the verdict itself.
        #expect(SessionTypeResolution.voiceMemo(reason: .farEndSilent).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.voiceMemo(reason: .mixUnfed).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.explicit(.callCapture).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.explicit(.voiceMemo).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.call(reason: .meetingEvidence).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.call(reason: .conferencingApp).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.call(reason: .farEndSpeech).suppressesSilentLegNote)
        #expect(!SessionTypeResolution.call(reason: .legUnavailable).suppressesSilentLegNote)
    }

    // MARK: - RecordingMode

    @Test func explicitSessionTypeMapping() {
        #expect(RecordingMode.auto.explicitSessionType == nil)
        #expect(RecordingMode.callCapture.explicitSessionType == .callCapture)
        #expect(RecordingMode.voiceMemo.explicitSessionType == .voiceMemo)
    }

    @Test func fromAPIStringAcceptsExactlyTheThreeTokens() {
        #expect(RecordingMode.fromAPIString("auto") == .auto)
        #expect(RecordingMode.fromAPIString("callCapture") == .callCapture)
        #expect(RecordingMode.fromAPIString("voiceMemo") == .voiceMemo)
    }

    @Test(arguments: ["", "Auto", "AUTO", "meeting", "callcapture", "voice_memo", " auto", "auto "])
    func fromAPIStringRejectsEverythingElse(raw: String) {
        #expect(RecordingMode.fromAPIString(raw) == nil)
    }

    // MARK: - Log line

    @Test func logLineRendersTypeReasonAndFlags() {
        let e = evidence(
            hasMeetingEvidence: true,
            nativeConferencingAppAtStart: false,
            systemLegDelivered: true,
            feederVerdict: .fed,
            themUtteranceCount: 4
        )
        let line = SessionTypeResolver.logLine(for: resolve(e), evidence: e)
        #expect(line == "[STOP] session type resolved: callCapture reason=meetingEvidence them=4 legDelivered=true feeder=fed meeting=true app=false")
    }

    @Test func logLineNeverCarriesTheMixerName() {
        // Metadata-only logging: the verdict renders as a bare token.
        let e = evidence(systemLegDelivered: false, feederVerdict: .unfed(mixerName: "Wave Link"))
        let line = SessionTypeResolver.logLine(for: resolve(e), evidence: e)
        #expect(line == "[STOP] session type resolved: voiceMemo reason=mixUnfed them=0 legDelivered=false feeder=unfed meeting=false app=false")
        #expect(!line.contains("Wave Link"))
    }

    @Test func logLineRendersUnknownAndAbsentVerdicts() {
        let unknown = evidence(nativeConferencingAppAtStart: true, systemLegDelivered: true, feederVerdict: .unknown)
        #expect(SessionTypeResolver.logLine(for: resolve(unknown), evidence: unknown)
            == "[STOP] session type resolved: callCapture reason=conferencingApp them=0 legDelivered=true feeder=unknown meeting=false app=true")

        let sck = evidence(requestedMode: .voiceMemo)
        #expect(SessionTypeResolver.logLine(for: resolve(sck), evidence: sck)
            == "[STOP] session type resolved: voiceMemo reason=explicit them=0 legDelivered=false feeder=n/a meeting=false app=false")
    }
}
