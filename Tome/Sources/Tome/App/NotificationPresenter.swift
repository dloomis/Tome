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

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
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

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let filePath = userInfo["filePath"] as? String {
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
