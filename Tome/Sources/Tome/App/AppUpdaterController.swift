import AppKit
import Sparkle

@MainActor
final class AppUpdaterController: NSObject, SPUUpdaterDelegate {
    private(set) var updater: SPUUpdater!
    private let userDriver: TomeUserDriver

    /// Queried before every update check (scheduled or user-initiated). While it
    /// returns true the check is refused — an update flow ends in an "Install
    /// and Relaunch" prompt that would terminate a live recording. Wired by
    /// `TomeApp` to `AppServices.isRecording`.
    var isRecordingProvider: (() -> Bool)?

    override init() {
        let hostBundle = Bundle.main
        userDriver = TomeUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
        updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: self
        )

        // Only start updater if EdDSA signing key is configured
        let edKey = hostBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !edKey.isEmpty else { return }

        do {
            try updater.start()
        } catch {
            presentStartupError()
        }
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle invokes this on the main thread before any update check.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try MainActor.assumeIsolated {
            try UpdatePolicy.mayPerformCheck(isRecording: isRecordingProvider?() ?? false)
        }
    }

    private func presentStartupError() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check For Updates"
        alert.informativeText = "The updater failed to start. Please verify you have the latest version of Tome and contact the developer if the issue persists."
        alert.runModal()
    }
}

@MainActor
final class TomeUserDriver: SPUStandardUserDriver {
    private static let sparkleErrorDomain = "SUSparkleErrorDomain"
    private static let installationErrorCode = 4005
    private static let installationWriteNoPermissionErrorCode = 4012

    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError

        guard let guidance = appManagementGuidance(for: nsError) else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = guidance.title
        alert.informativeText = guidance.message
        alert.addButton(withTitle: "OK")
        alert.runModal()

        acknowledgement()
    }

    private func appManagementGuidance(for error: NSError) -> (title: String, message: String)? {
        if containsPermissionWriteFailure(error) {
            return permissionAlertContent()
        }

        guard error.domain == Self.sparkleErrorDomain else {
            return nil
        }

        let installedInApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
        guard installedInApplications else {
            return nil
        }

        if error.code == Self.installationErrorCode {
            let description = error.localizedDescription
            let likelyInstallerHandshakeFailure =
                description == "An error occurred while running the updater. Please try again later." ||
                description == "An error occurred while launching the installer. Please try again later." ||
                description == "An error occurred while connecting to the installer. Please try again later."

            if likelyInstallerHandshakeFailure {
                return permissionAlertContent()
            }
        }

        return nil
    }

    private func containsPermissionWriteFailure(_ error: NSError) -> Bool {
        if error.domain == Self.sparkleErrorDomain && error.code == Self.installationWriteNoPermissionErrorCode {
            return true
        }

        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, containsPermissionWriteFailure(underlying) {
            return true
        }

        if let underlyingErrors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            return underlyingErrors.contains(where: containsPermissionWriteFailure(_:))
        }

        return false
    }

    private func permissionAlertContent() -> (title: String, message: String) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "This app"

        let message = """
        macOS blocked \(appName) from replacing the installed app.

        To allow updates:
        1. Open System Settings > Privacy & Security > App Management
        2. Enable \(appName)
        3. Approve the password prompt
        4. Try the update again

        If you already allowed it, quit \(appName) and retry the update.
        """

        return ("Allow \(appName) to Install Updates", message)
    }
}
