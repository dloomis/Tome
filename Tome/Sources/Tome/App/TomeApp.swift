import SwiftUI
import AppKit
import Sparkle

@main
struct TomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()
    @State private var services = AppServices()
    private let updaterController = AppUpdaterController()
    private let apiServer = APIServer()

    var body: some Scene {
        // Single-instance Window (not WindowGroup) — on macOS 26, WindowGroup
        // adds a "+" pill to the toolbar that opens duplicate instances. Tome
        // is a single-window utility, so the singleton Window scene is correct.
        Window("Tome", id: "main") {
            ContentView(settings: settings, apiServer: apiServer, services: services)
                .onAppear {
                    settings.applyScreenShareVisibility()
                    appDelegate.postProcessingQueue = services.postProcessingQueue
                    appDelegate.transcriptLogger = services.transcriptLogger
                    appDelegate.sessionStore = services.sessionStore
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .saveItem) {
                // Kept always-enabled (rather than `.disabled(...)` toggled by an
                // `@FocusedValue`) because dynamic enable/disable forces SwiftUI to
                // rebuild the main menu on focus changes, which crashes inside
                // `NSContextMenuImpl` on macOS 26 (FB-pending). The action is a
                // no-op when there's nothing to save — see `ContentView.saveTranscriptToFile`.
                Button("Save Transcript...") {
                    services.saveTranscriptAction?()
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Recover from WAV...") {
                    services.recoverFromWAVAction?()
                }
                // Cmd+Opt+R — Cmd+R and Cmd+Shift+R are already taken by Start
                // Call Capture / Start Voice Memo in `ControlBar.swift`. The window
                // shortcuts win when the main window is key, so the menu shortcut
                // must avoid both.
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
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

    /// Set by `TomeApp` on launch so the terminate handler can flush + fsync the
    /// live transcript before quitting. Without this, the last 1–2 utterances
    /// buffered in `TranscriptLogger` would be lost on Cmd-Q during an active session.
    var transcriptLogger: TranscriptLogger?
    var sessionStore: SessionStore?

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Emergency flush: if a session is live, drain its writer state so the last
        // utterance and JSONL record reach disk before we exit. Hard 2s cap so a stuck
        // FS doesn't block quit. The session's WAV in /var/folders is discarded — no
        // diarization for the in-flight session, but the markdown transcript is durable.
        if let logger = transcriptLogger, let store = sessionStore {
            let sema = DispatchSemaphore(value: 0)
            Task {
                _ = await logger.endSession()
                await store.endSession()
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 2.0)
        }

        // If any post-processing job is in flight, briefly block termination with a
        // native alert and wait for the queue to drain (with a 60s cap). The
        // per-utterance flush means the transcript is already safe on disk; we're
        // only waiting for diarization + frontmatter finalization to complete.
        guard let queue = postProcessingQueue, queue.isAnyJobRunning else {
            postProcessingQueue?.shutdown()
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
            queue.shutdown()
            return .terminateNow
        }

        // User chose to wait — poll until queue drains or timeout.
        quitWaitTask?.cancel()
        quitWaitTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while queue.isAnyJobRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            queue.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
