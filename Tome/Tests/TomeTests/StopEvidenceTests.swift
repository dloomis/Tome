import Foundation
import Testing

@testable import Tome

// Pure helpers behind `ContentView.stopSession`'s session-type resolution
// (docs/superpowers/specs/2026-09-26-single-record-button-auto-mode.md §3/§4).
// The read ORDERING in stopSession (engine telemetry before stop, utterance
// count after the drain) is documented there; these pin what gets computed.

@Suite("Stop evidence helpers")
struct StopEvidenceTests {

    // MARK: themUtteranceCount

    @Test func countsOnlyThemWithNonWhitespaceText() {
        let utterances = [
            Utterance(text: "hello from me", speaker: .you),
            Utterance(text: "hi, far end here", speaker: .them),
            Utterance(text: "   \n\t ", speaker: .them),
            Utterance(text: "", speaker: .them),
            Utterance(text: "  another line  ", speaker: .them),
        ]
        #expect(StopEvidence.themUtteranceCount(in: utterances) == 2)
    }

    @Test func youLinesNeverCount() {
        let utterances = [
            Utterance(text: "only me talking", speaker: .you),
            Utterance(text: "still me", speaker: .you),
        ]
        #expect(StopEvidence.themUtteranceCount(in: utterances) == 0)
    }

    @Test func emptyStoreCountsZero() {
        #expect(StopEvidence.themUtteranceCount(in: []) == 0)
    }

    // MARK: retypePlan

    private let noteFolder = URL(fileURLWithPath: "/vault/Meetings")

    private func intent(
        _ mode: RecordingMode,
        callLabel: String = "Call Recording",
        voiceLabel: String = "Voice Memo"
    ) -> ActiveSessionIntent {
        ActiveSessionIntent(
            mode: mode,
            hadMeetingEvidence: false,
            nativeConferencingAppAtStart: false,
            filenameCallLabel: callLabel,
            filenameVoiceLabel: voiceLabel
        )
    }

    private func plan(_ mode: RecordingMode, _ type: SessionType, voicePath: String = "/vault/Voice") -> RetypePlan? {
        StopEvidence.retypePlan(
            intent: intent(mode),
            resolvedType: type,
            vaultVoicePath: voicePath,
            currentNoteFolder: noteFolder
        )
    }

    @Test func autoResolvedMemoGetsAPlan() {
        let p = plan(.auto, .voiceMemo)
        #expect(p == RetypePlan(
            voiceFolder: URL(fileURLWithPath: "/vault/Voice"),
            voiceFilenameTypeLabel: "Voice Memo",
            callFilenameTypeLabel: "Call Recording"
        ))
    }

    /// The plan's labels are the intent's START-time snapshot (the labels the
    /// provisional note was named with), not whatever Settings says at stop.
    @Test func planCarriesStartTimeLabelsFromIntent() {
        let p = StopEvidence.retypePlan(
            intent: intent(.auto, callLabel: "Meeting (at start)", voiceLabel: "Memo (at start)"),
            resolvedType: .voiceMemo,
            vaultVoicePath: "/vault/Voice",
            currentNoteFolder: noteFolder
        )
        #expect(p?.callFilenameTypeLabel == "Meeting (at start)")
        #expect(p?.voiceFilenameTypeLabel == "Memo (at start)")
    }

    @Test func autoResolvedCallHasNoPlan() {
        #expect(plan(.auto, .callCapture) == nil)
    }

    @Test func explicitSessionsNeverRetype() {
        #expect(plan(.voiceMemo, .voiceMemo) == nil)
        #expect(plan(.callCapture, .callCapture) == nil)
    }

    @Test func tildeVoicePathIsExpanded() {
        let p = plan(.auto, .voiceMemo, voicePath: "~/Notes/Voice")
        let expected = NSString(string: "~/Notes/Voice").expandingTildeInPath
        #expect(p?.voiceFolder.path == expected)
        #expect(p?.voiceFolder.path.hasPrefix("~") == false)
    }

    @Test func emptyVoicePathRetypesInPlace() {
        #expect(plan(.auto, .voiceMemo, voicePath: "")?.voiceFolder == noteFolder)
        #expect(plan(.auto, .voiceMemo, voicePath: "   ")?.voiceFolder == noteFolder)
    }
}
