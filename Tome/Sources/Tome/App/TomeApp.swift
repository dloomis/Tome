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
    @FocusedValue(\.saveTranscript) private var saveTranscript
    private let updaterController = AppUpdaterController()
    private let apiServer = APIServer()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, apiServer: apiServer)
                .onAppear {
                    settings.applyScreenShareVisibility()
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
        }
        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
        }
        MenuBarExtra {
            Text("Tome")
                .font(.headline)
            Divider()
            Button("Quit Tome") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "book.closed")
                .symbolRenderingMode(.monochrome)
        }
    }
}

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
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
                }
            }
        }
    }
}
