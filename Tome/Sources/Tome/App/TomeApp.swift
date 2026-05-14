import SwiftUI
import AppKit
import Sparkle

// MARK: - Focused Value for Save Transcript

struct SaveTranscriptKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var saveTranscript: (() -> Void)? {
        get { self[SaveTranscriptKey.self] }
        set { self[SaveTranscriptKey.self] = newValue }
    }
}

@main
struct TomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()
    @State private var services = AppServices()
    @FocusedValue(\.saveTranscript) private var saveTranscript
    private let updaterController = AppUpdaterController()
    private let apiServer = APIServer()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, apiServer: apiServer, services: services)
                .onAppear {
                    settings.applyScreenShareVisibility()
                    appDelegate.postProcessingQueue = services.postProcessingQueue
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .saveItem) {
                Button("Save Transcript...") {
                    saveTranscript?()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saveTranscript == nil)
            }
            // Replace the toolbar command group (Show/Hide Toolbar, Customize
            // Toolbar, Enter Full Screen) with our own minimal contents. Tome
            // has no toolbar and never needs full-screen; the only item we want
            // in the View menu is Logs.
            CommandGroup(replacing: .toolbar) {
                Button("Logs") {
                    let path = "/tmp/tome.log"
                    if !FileManager.default.fileExists(atPath: path) {
                        FileManager.default.createFile(atPath: path, contents: nil)
                    }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
        }
        MenuBarExtra {
            Text("Tome")
                .font(.headline)
            if services.postProcessingQueue.isAnyJobRunning {
                let count = services.postProcessingQueue.inFlightCount
                Text(count == 1 ? "Finalizing 1 transcript…" : "Finalizing \(count) transcripts…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Quit Tome") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Filled icon while any background finalization is in flight — gives a
            // peripheral-vision cue without taking over the menu bar.
            Image(systemName: services.postProcessingQueue.isAnyJobRunning ? "book.closed.fill" : "book.closed")
                .symbolRenderingMode(.monochrome)
                .symbolEffect(.pulse, options: .repeating, isActive: services.postProcessingQueue.isAnyJobRunning)
        }
    }
}

/// Observes new window creation, applies screen-share visibility, and blocks app
/// termination while background finalization jobs are still running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?
    private var quitWaitTask: Task<Void, Never>?

    /// Set by `TomeApp` on launch. The termination handler observes this to decide
    /// whether a quit needs to wait for finalization.
    var postProcessingQueue: PostProcessingQueue?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tome is a single-window utility — disable AppKit's automatic window
        // tabbing so the View menu doesn't sprout "Show Tab Bar / Show All Tabs"
        // entries from a feature we never use.
        NSWindow.allowsAutomaticWindowTabbing = false

        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
            AppDelegate.disableFullScreen(on: window)
        }

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let hide = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                    AppDelegate.disableFullScreen(on: window)
                }
            }
        }
    }

    /// Opt the window out of full-screen mode so AppKit drops "Enter Full Screen"
    /// from the View menu. Tome's main window is 320x560 and full-screening it
    /// makes no sense; the Settings window similarly shouldn't full-screen.
    private static func disableFullScreen(on window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.remove(.fullScreenPrimary)
        behavior.remove(.fullScreenAuxiliary)
        behavior.insert(.fullScreenNone)
        window.collectionBehavior = behavior
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If any post-processing job is in flight, briefly block termination with a
        // native alert and wait for the queue to drain (with a 60s cap). The
        // per-utterance flush means the transcript is already safe on disk; we're
        // only waiting for diarization + frontmatter finalization to complete.
        guard let queue = postProcessingQueue, queue.isAnyJobRunning else {
            return .terminateNow
        }

        let count = queue.inFlightCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Finalizing 1 transcript…" : "Finalizing \(count) transcripts…"
        alert.informativeText = "Tome is still applying speaker labels to recent recordings. Wait a moment, or quit now — the transcript itself is already saved."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            return .terminateNow
        }

        // User chose to wait — poll until queue drains or timeout.
        quitWaitTask?.cancel()
        quitWaitTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while queue.isAnyJobRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
