import AppKit
import Observation
import SwiftUI

/// Floating "Record this meeting?" prompt (spec
/// `docs/superpowers/specs/2026-10-06-record-this-meeting-prompt.md` §3),
/// shown when a meeting-titled conferencing window and sustained far-end audio
/// say a call is live while Tome is idle.
///
/// Same non-activating `FloatingPromptPanel` as the auto-stop countdown: floats
/// over every Space and full-screen apps, never takes key focus, never
/// activates Tome, first-mouse buttons. **Silent** — unlike the auto-stop
/// panel (which beeps into silence) this one appears during a live meeting and
/// would beep into someone's sentence.
///
/// The controller only presents. Its buttons call the supplied closures and
/// nothing else; the caller decides when to `hide()`. The one thing it does on
/// its own is time out: `autoHideSeconds` after a show, if still visible and
/// not re-shown, it reports a decline (the notification stays the durable
/// path).
@MainActor
final class MeetingJoinPanelController {
    /// How long the panel stays up unanswered before it reports a decline.
    nonisolated static let autoHideSeconds: Duration = .seconds(60)

    /// Panel and notification title.
    nonisolated static let title = "Record this meeting?"

    private var panel: FloatingPromptPanel?
    private let model = MeetingJoinPanelModel()
    private var autoHideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Present (or, when already visible, update in place) the prompt.
    /// `hiddenFromSharing` should be `AppSettings.hideFromScreenShare` — it
    /// matters more here than anywhere: a "Record this meeting?" panel caught
    /// in a shared screen is visible to the people being recorded.
    ///
    /// `onDecline` fires for Not This Meeting, the ✕, and — unless `onTimeout`
    /// is supplied — the `autoHideSeconds` timeout. Every show (re)arms the
    /// timeout; `hide()` cancels it.
    func show(
        appName: String,
        meetingTitle: String,
        hiddenFromSharing: Bool,
        onRecord: @escaping () -> Void,
        onDecline: @escaping () -> Void,
        onTimeout: (() -> Void)? = nil
    ) {
        model.body = Self.bodyLine(appName: appName, meetingTitle: meetingTitle)
        model.onRecord = onRecord
        model.onDecline = onDecline

        let panel = self.panel ?? FloatingPromptPanel.make(rootView: MeetingJoinPanelView(model: model))
        self.panel = panel
        panel.applySharing(hidden: hiddenFromSharing)

        let wasVisible = panel.isVisible
        panel.refitToContent(keepingTopEdge: wasVisible)
        if !wasVisible {
            panel.positionTopCenter()
            panel.orderFrontRegardless()
            // Deliberately no NSSound.beep(): this fires into a live mic.
        }

        armAutoHide(onTimeout ?? onDecline)
    }

    /// Idempotent. Cancels the pending timeout. The panel is kept (not
    /// released) for the next show.
    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - Pure helpers (shared with NotificationPresenter, unit-tested)

    /// "<title> in <appName> is live and Tome isn't recording." — the body
    /// line for both the panel and the notification.
    nonisolated static func bodyLine(appName: String, meetingTitle: String) -> String {
        "\(meetingTitle) in \(appName) is live and Tome isn't recording."
    }

    // MARK: - Private

    private func armAutoHide(_ onTimeout: @escaping () -> Void) {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoHideSeconds)
            // Main-actor isolated: a hide() or re-show that ran first has
            // already cancelled this task, so the check below is race-free.
            guard !Task.isCancelled, let self, self.isVisible else { return }
            self.autoHideTask = nil
            onTimeout()
        }
    }
}

// MARK: - Model + view

@MainActor
@Observable
private final class MeetingJoinPanelModel {
    var body: String = ""
    @ObservationIgnored var onRecord: () -> Void = {}
    @ObservationIgnored var onDecline: () -> Void = {}
}

private struct MeetingJoinPanelView: View {
    let model: MeetingJoinPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recordRed)
                Text(MeetingJoinPanelController.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.fg1)
                Spacer(minLength: 8)
                Button(action: { model.onDecline() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.fg2)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Not This Meeting")
            }

            Text(model.body)
                .font(.system(size: 12))
                .foregroundStyle(Color.fg2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: { model.onDecline() }) {
                    Text("Not This Meeting")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.fg1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Primary: the question's affirmative answer gets the filled accent.
                Button(action: { model.onRecord() }) {
                    Text("Record")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.bg0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accent1)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Deliberately no .keyboardShortcut(.defaultAction): keystrokes
                // meant for the meeting app must never answer this panel.
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.bg0.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08))
        )
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Log lines (spec §6)

/// `[JOIN-PROMPT]` diagnostic lines. App name only — the meeting title is a
/// subject line and stays out of the log store, like `[DETECT]`.
enum JoinPromptLog {
    enum DeclineReason: String, Sendable {
        case button, disabled
    }

    static func prompted(appName: String) -> String {
        "[JOIN-PROMPT] prompted — \(appName)"
    }

    static func withdrawn(reason: String) -> String {
        "[JOIN-PROMPT] withdrawn (\(reason))"
    }

    static let accepted = "[JOIN-PROMPT] accepted"

    /// The panel timed out unanswered. Not a decline: the notification stays
    /// up and the policy stays `prompted` until the call ends (spec §3).
    static let panelTimedOut = "[JOIN-PROMPT] panel timed out — notification remains"

    static func declined(_ reason: DeclineReason) -> String {
        "[JOIN-PROMPT] declined (\(reason.rawValue))"
    }
}
