import Foundation
import AppKit
import UserNotifications

/// Posts user notifications when a `PostProcessingJob` completes. Clicking the
/// notification reveals the finalized markdown file in Finder.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    private var authorized = false
    private var authRequested = false

    // MARK: - Silence stop confirmation

    /// Category + action identifiers for the silence stop prompt. The category is
    /// registered in `init` so the action buttons exist before the first post.
    nonisolated static let silenceCategoryID = "TOME_SILENCE_PROMPT"
    nonisolated static let silenceStopActionID = "TOME_SILENCE_STOP"
    nonisolated static let silenceKeepActionID = "TOME_SILENCE_KEEP"
    /// Fixed request identifier so a re-post replaces (not stacks) and the prompt
    /// can be withdrawn by id when answered in-app or audio resumes.
    private nonisolated static let silencePromptRequestID = "tome-silence-prompt"

    /// Registered by `ContentView` during its boot task — same callback wiring
    /// rationale as `AppServices.saveTranscriptAction`. Invoked on the main actor
    /// when the user answers the silence prompt from the notification.
    var silenceStopAction: (() -> Void)?
    var silenceKeepAction: (() -> Void)?

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self

        let stop = UNNotificationAction(identifier: Self.silenceStopActionID, title: "Stop Recording", options: [])
        let keep = UNNotificationAction(identifier: Self.silenceKeepActionID, title: "Keep Recording", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.silenceCategoryID,
                actions: [stop, keep],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// Ask for permission lazily — only when we actually have a notification to post.
    /// Calling it repeatedly is safe; it's a no-op after the first call.
    func requestAuthorizationIfNeeded() async {
        guard !authRequested else { return }
        authRequested = true
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
    }

    /// Post a "Meeting transcribed" notification. Silent if permission was denied.
    func postCompletion(savedURL: URL, sessionType: SessionType) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        let filename = savedURL.deletingPathExtension().lastPathComponent
        switch sessionType {
        case .callCapture:
            content.title = "Meeting transcribed"
        case .voiceMemo:
            content.title = "Voice memo saved"
        }
        content.body = filename
        content.sound = nil
        content.userInfo = ["filePath": savedURL.path]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Ask the user to confirm stopping after prolonged silence. Mirrors the
    /// in-app prompt in `ControlBar` for when the Tome window is hidden behind
    /// the meeting app. Recording continues until an action is chosen — this
    /// notification never stops anything by itself.
    func postSilencePrompt(silentForSeconds: Int) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Still there? Tome is recording silence"
        content.body = "No audio for \(Self.silenceDescription(silentForSeconds)). Recording continues until you stop it."
        content.sound = .default
        content.categoryIdentifier = Self.silenceCategoryID

        let request = UNNotificationRequest(
            identifier: Self.silencePromptRequestID,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Withdraw the silence prompt — answered in-app, audio resumed, or the
    /// session ended some other way. Safe to call when nothing is posted.
    func clearSilencePrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.silencePromptRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.silencePromptRequestID])
    }

    private static func silenceDescription(_ seconds: Int) -> String {
        seconds < 120 ? "\(seconds) seconds" : "\(seconds / 60) minutes"
    }

    // MARK: - Capture stall

    /// One fixed identifier per leg so a re-post replaces (not stacks) and the
    /// alert can be withdrawn when samples resume.
    private nonisolated static func stallRequestID(leg: String) -> String {
        "tome-capture-stall-\(leg.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }

    /// A capture leg (microphone / system audio) stopped delivering samples
    /// mid-recording. The control-bar error text is invisible behind the meeting
    /// app — this is the signal that actually reaches the user in time to save
    /// the rest of the meeting.
    func postCaptureStall(leg: String, detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: \(leg) capture stalled"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.stallRequestID(leg: leg),
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Withdraw a leg's stall alert after samples resume. Safe when nothing is posted.
    func clearCaptureStall(leg: String) {
        let center = UNUserNotificationCenter.current()
        let id = Self.stallRequestID(leg: leg)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Mic fallback / digital silence / silent system leg

    /// Fixed identifiers so re-posts replace (not stack) and each can be
    /// withdrawn when its condition clears.
    private nonisolated static let micFallbackRequestID = "tome-mic-fallback"
    private nonisolated static let micSilenceRequestID = "tome-mic-digital-silence"
    private nonisolated static let systemSilentRequestID = "tome-system-audio-silent"

    /// Capture is running on a device other than the user's selection (the
    /// selected mic's UID resolved to no present device, or its bind failed and
    /// the engine fell back to the system default). Previously this fallback was
    /// completely silent — a meeting could record off the built-in mic with no
    /// indication until the transcript was read.
    func postMicFallback(detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: recording from a different microphone"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.micFallbackRequestID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Withdraw the fallback alert after capture lands back on the selected
    /// device (or the session ends). Safe when nothing is posted.
    func clearMicFallback() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.micFallbackRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.micFallbackRequestID])
    }

    /// The mic tap is delivering buffers whose samples are all exactly zero — an
    /// unfed virtual device (audio-router app not running) or a hard-muted
    /// input. Real microphones always carry a non-zero noise floor.
    func postMicDigitalSilence(detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: microphone is recording silence"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.micSilenceRequestID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func clearMicDigitalSilence() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.micSilenceRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.micSilenceRequestID])
    }

    // MARK: - Call audio source (device / "lean-in" mode)

    private nonisolated static let systemSourceFallbackRequestID = "tome-system-source-fallback"
    private nonisolated static let systemSourceSilenceRequestID = "tome-system-source-silence"

    /// The session is configured to capture call audio from a mixer's virtual
    /// input device, but is recording via ScreenCaptureKit instead (device
    /// absent, bind failed, or the device is the mic's own). Same rationale as
    /// `postMicFallback`: recording from the wrong source must never be silent.
    func postSystemSourceFallback(detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: capturing call audio a different way"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.systemSourceFallbackRequestID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Withdraw the source-fallback alert once a rebuild lands back on the
    /// configured device (or the session ends). Safe when nothing is posted.
    func clearSystemSourceFallback() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.systemSourceFallbackRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.systemSourceFallbackRequestID])
    }

    /// The configured call-audio device is delivering buffers whose samples are
    /// all exactly zero — the mixer app isn't running (its virtual devices stay
    /// registered regardless) or the mix is empty. A mix bus with any live
    /// channel always carries a non-zero noise floor.
    func postSystemSourceSilence(detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: call audio device is delivering silence"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.systemSourceSilenceRequestID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func clearSystemSourceSilence() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.systemSourceSilenceRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.systemSourceSilenceRequestID])
    }

    /// A call capture's system leg has produced no audible content — either 60s
    /// into a live session (watchdog one-shot) or for an entire finished session
    /// (stop-time note). Fixed ID: the stop-time post replaces the mid-session
    /// one instead of stacking.
    func postSystemAudioSilent(detail: String) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tome: no system audio detected"
        content.body = detail
        content.sound = nil

        let request = UNNotificationRequest(identifier: Self.systemSilentRequestID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Post-processing failure

    /// A finalization job failed after the session ended. The capture WAVs were
    /// preserved (see PostProcessingJob's verified-success cleanup) and the next
    /// launch offers recovery — but the user needs to know now, not at next launch.
    func postJobFailure(message: String, sessionType: SessionType) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = sessionType == .voiceMemo
            ? "Voice memo finalization failed"
            : "Meeting finalization failed"
        content.body = "\(message) The audio was kept — Tome will offer recovery at next launch."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Short-session discard

    /// A session stopped at/under the user's discard threshold and was removed instead
    /// of saved (see `AppSettings.discardShortMeetings`). Without this, the transcript
    /// silently vanishing from the vault reads as a bug — this confirms it was intended.
    /// No sessionType parameter: only call captures are ever discarded.
    func postDiscard(durationSeconds: Int) async {
        await requestAuthorizationIfNeeded()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Short recording discarded"
        content.body = "A \(durationSeconds)s recording was at or under your discard threshold and wasn't saved."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content

        if content.categoryIdentifier == Self.silenceCategoryID {
            let action = response.actionIdentifier
            Task { @MainActor in
                switch action {
                case Self.silenceStopActionID:
                    self.silenceStopAction?()
                case Self.silenceKeepActionID:
                    self.silenceKeepAction?()
                default:
                    // Banner body clicked — bring Tome forward so the user can
                    // answer via the in-app prompt instead.
                    NSApp.activate()
                }
            }
            completionHandler()
            return
        }

        if let filePath = content.userInfo["filePath"] as? String {
            let url = URL(fileURLWithPath: filePath)
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Display banners even while the app is foregrounded.
        completionHandler([.banner])
    }
}
