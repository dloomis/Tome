import Observation

/// Confirmation gate for the main "Stop Recording" button. A single accidental
/// click mid-meeting used to tear the session down irreversibly (the transcript
/// finalizes and post-processing starts), so the button now routes through this
/// model, which presents an alert and only fires `onConfirm` on an explicit
/// "Stop Recording" in the dialog.
///
/// Only the main button confirms. The silence prompt's "Stop & Save" and the
/// notification stop action are already confirmations, and the HTTP API must
/// stay scriptable — all three bypass this model and call stop directly.
@Observable
@MainActor
final class StopConfirmationModel {
    /// Bound to ContentView's `.alert`. SwiftUI writes `false` here on any
    /// dismissal (button tap, Esc) in addition to running the tapped button's
    /// action — so the confirm/cancel semantics live exclusively in
    /// `confirmStop()`/`cancelStop()`, never in the binding itself.
    var isPresented = false

    /// Wired to `stopSession()` by ContentView at boot.
    @ObservationIgnored var onConfirm: () -> Void = {}

    /// Main Stop button pressed — ask instead of stopping.
    func requestStop() {
        isPresented = true
    }

    /// Dialog "Stop Recording": dismiss and stop the session.
    func confirmStop() {
        isPresented = false
        onConfirm()
    }

    /// Dialog "Cancel": dismiss, change nothing.
    func cancelStop() {
        isPresented = false
    }

    /// The session ended through another path (capture error, API stop,
    /// notification stop) while the dialog was up — withdraw it silently.
    func recordingDidEnd() {
        isPresented = false
    }
}
