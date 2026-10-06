import AppKit
import Observation
import SwiftUI

/// Floating countdown for the forgotten-recording failsafe (spec
/// `docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md` §6).
///
/// A non-activating `FloatingPromptPanel` (see `FloatingPromptPanel.swift`):
/// it floats over every Space (and full-screen apps), never takes key focus,
/// and never activates Tome — so a Return or Space typed into the meeting app
/// can't answer it by accident. That is the reason this isn't an `NSAlert`
/// (which would also block the main actor the engine lives on).
///
/// The controller only presents. Its buttons call the supplied closures and
/// nothing else; the caller decides when to `hide()`.
@MainActor
final class AutoStopPanelController {
    private var panel: FloatingPromptPanel?
    private let model = AutoStopPanelModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Present (or, when already visible, update in place) the countdown.
    /// `hiddenFromSharing` should be `AppSettings.hideFromScreenShare` — the
    /// panel follows the stealth toggle like every other Tome window. One alert
    /// sound plays on the hidden → visible transition only.
    func show(
        line: String,
        deadline: ContinuousClock.Instant,
        hiddenFromSharing: Bool,
        onKeep: @escaping () -> Void,
        onStopNow: @escaping () -> Void
    ) {
        model.line = line
        model.deadline = deadline
        model.onKeep = onKeep
        model.onStopNow = onStopNow

        let panel = self.panel ?? FloatingPromptPanel.make(rootView: AutoStopPanelView(model: model))
        self.panel = panel
        panel.applySharing(hidden: hiddenFromSharing)

        let wasVisible = panel.isVisible
        panel.refitToContent(keepingTopEdge: wasVisible)
        if !wasVisible {
            panel.positionTopCenter()
            panel.orderFrontRegardless()
            NSSound.beep()
        }
    }

    /// Idempotent. The panel is kept (not released) for the next show.
    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Pure helpers (shared with ControlBar, unit-tested)

    /// Whole seconds left until `deadline`, rounded up (so a fresh 30 s
    /// countdown reads 0:30, not 0:29) and clamped at 0.
    nonisolated static func remainingSeconds(
        until deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Int {
        let remaining = deadline - now
        guard remaining > .zero else { return 0 }
        let parts = remaining.components
        let whole = Int(parts.seconds)
        return parts.attoseconds > 0 ? whole + 1 : whole
    }

    /// `m:ss`, clamped at 0:00.
    nonisolated static func formatCountdown(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

// MARK: - Model + view

@MainActor
@Observable
private final class AutoStopPanelModel {
    var line: String = ""
    var deadline: ContinuousClock.Instant = .now
    @ObservationIgnored var onKeep: () -> Void = {}
    @ObservationIgnored var onStopNow: () -> Void = {}
}

private struct AutoStopPanelView: View {
    let model: AutoStopPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recordRed)
                Text("Recording will stop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.fg1)
            }

            Text(model.line)
                .font(.system(size: 12))
                .foregroundStyle(Color.fg2)
                .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let seconds = AutoStopPanelController.remainingSeconds(
                    until: model.deadline, now: .now
                )
                Text(AutoStopPanelController.formatCountdown(seconds))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.fg1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: 8) {
                Button(action: { model.onStopNow() }) {
                    Text("Stop Now")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.fg1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.recordRed.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.recordRed.opacity(0.3)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Prominent: the safe choice gets the filled accent.
                Button(action: { model.onKeep() }) {
                    Text("Keep Recording")
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
