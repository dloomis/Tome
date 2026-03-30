import SwiftUI
import AppKit
import Sparkle

@main
struct TomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()
    @State private var isRecording = false
    private let updaterController = AppUpdaterController()
    private let apiServer = APIServer()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, apiServer: apiServer, isRecording: $isRecording)
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
            MenuBarLabel(isRecording: isRecording)
        }
    }
}

/// Menu bar icon that overlays a pulsating red recording dot when active.
private struct MenuBarLabel: View {
    let isRecording: Bool
    @State private var pulse = false

    var body: some View {
        Image(systemName: isRecording ? "book.closed.circle.fill" : "book.closed")
            .symbolRenderingMode(isRecording ? .palette : .monochrome)
            .foregroundStyle(isRecording ? .red : .primary)
            .opacity(isRecording && pulse ? 0.4 : 1.0)
            .animation(
                isRecording
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: isRecording) { _, recording in
                pulse = recording
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
