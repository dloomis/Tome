import Foundation
import Testing
import UserNotifications
@testable import Tome

/// Copy, notification registration and log lines behind the "Record this
/// meeting?" surfaces — spec
/// `docs/superpowers/specs/2026-10-06-record-this-meeting-prompt.md` §3, §6.
@Suite struct MeetingJoinPanelTests {

    // MARK: - Copy

    @Test func bodyLineNamesMeetingAndApp() {
        #expect(MeetingJoinPanelController.bodyLine(appName: "Teams", meetingTitle: "Weekly sync")
                == "Weekly sync in Teams is live and Tome isn't recording.")
    }

    @Test func titleCopy() {
        #expect(MeetingJoinPanelController.title == "Record this meeting?")
    }

    @Test func autoHideIsSixtySeconds() {
        #expect(MeetingJoinPanelController.autoHideSeconds == .seconds(60))
    }

    // MARK: - Notification categories

    @Test func categoriesRegisteredInOneSet() {
        let ids = Set(NotificationPresenter.notificationCategories().map(\.identifier))
        #expect(ids == [
            NotificationPresenter.silenceCategoryID,
            NotificationPresenter.autoStopCategoryID,
            NotificationPresenter.meetingJoinCategoryID,
        ])
    }

    @Test func meetingJoinCategoryHasRecordAndDecline() throws {
        let category = try #require(
            NotificationPresenter.notificationCategories()
                .first { $0.identifier == "TOME_MEETING_JOIN_PROMPT" }
        )
        let actions = category.actions.map { ($0.identifier, $0.title) }
        #expect(actions.count == 2)
        #expect(actions[0] == ("TOME_MEETING_JOIN_RECORD", "Record"))
        #expect(actions[1] == ("TOME_MEETING_JOIN_DECLINE", "Not This Meeting"))
    }

    @Test func existingCategoriesKeepTheirActions() throws {
        let categories = NotificationPresenter.notificationCategories()
        let silence = try #require(categories.first { $0.identifier == NotificationPresenter.silenceCategoryID })
        #expect(silence.actions.map(\.identifier)
                == [NotificationPresenter.silenceStopActionID, NotificationPresenter.silenceKeepActionID])
        let autoStop = try #require(categories.first { $0.identifier == NotificationPresenter.autoStopCategoryID })
        #expect(autoStop.actions.map(\.identifier)
                == [NotificationPresenter.autoStopKeepActionID, NotificationPresenter.autoStopStopNowActionID])
    }

    // MARK: - Log lines

    @Test func logLinesCarryAppNameOnly() {
        #expect(JoinPromptLog.prompted(appName: "Teams") == "[JOIN-PROMPT] prompted — Teams")
        #expect(JoinPromptLog.withdrawn(reason: "recording") == "[JOIN-PROMPT] withdrawn (recording)")
        #expect(JoinPromptLog.accepted == "[JOIN-PROMPT] accepted")
        #expect(JoinPromptLog.declined(.button) == "[JOIN-PROMPT] declined (button)")
        #expect(JoinPromptLog.panelTimedOut == "[JOIN-PROMPT] panel timed out — notification remains")
        #expect(JoinPromptLog.declined(.disabled) == "[JOIN-PROMPT] declined (disabled)")
    }
}
