import AppKit
import SwiftUI

/// Shared `NSPanel` machinery for Tome's floating prompts — the
/// forgotten-recording countdown (`AutoStopPanelController`, spec
/// `2026-10-06-forgotten-recording-failsafe.md` §6) and the "Record this
/// meeting?" prompt (`MeetingJoinPanelController`, spec
/// `2026-10-06-record-this-meeting-prompt.md` §3).
///
/// A non-activating panel: it floats over every Space (and full-screen apps),
/// never takes key focus, and never activates Tome — so a Return or Space
/// typed into the meeting app can't answer it by accident. That is the reason
/// these aren't `NSAlert`s (which would also block the main actor the engine
/// lives on).
///
/// Never key, never main: the panel must not take focus from the meeting app.
/// Mouse clicks still reach its buttons (see `FirstMouseHostingView`).
final class FloatingPromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A configured, not-yet-shown panel hosting `rootView`. Callers set
    /// `sharingType` on every show (it follows `hideFromScreenShare`).
    @MainActor
    static func make<Content: View>(rootView: Content) -> FloatingPromptPanel {
        let panel = FloatingPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let host = FirstMouseHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// `.none` hides the panel from screen capture/sharing (follows
    /// `AppSettings.hideFromScreenShare` like every other Tome window).
    @MainActor
    func applySharing(hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }

    /// Refit to the (possibly re-wrapped) content, keeping the top edge fixed
    /// when `keepingTopEdge` so an in-place update doesn't jump the panel
    /// upward.
    @MainActor
    func refitToContent(keepingTopEdge: Bool) {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let top = frame.maxY
        setContentSize(content.fittingSize)
        if keepingTopEdge {
            setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
        }
    }

    /// Top-center of the screen holding the mouse, a little below the menu bar.
    @MainActor
    func positionTopCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12
        )
        setFrameOrigin(origin)
    }
}

/// The first click on an inactive app's panel should press the button, not
/// merely "focus" the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
