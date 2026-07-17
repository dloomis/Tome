# Stop-Recording Confirmation Dialog

**Date:** 2026-07-13
**Status:** Approved (design); pending implementation
**Branch:** `stop-recording-confirmation`

## Problem

It is too easy to stop a recording. The main "Stop Recording" button in the
control bar (and its ⌘. shortcut) tears the session down on a single click,
and users keep ending recordings mid-meeting by accident. A stopped session
cannot be resumed — the transcript is finalized and post-processing starts —
so an accidental stop is expensive.

## Acceptance criteria (user story)

Given I'm recording,
when I click **Stop Recording**,
then I get a prompt "Are you sure you want to stop recording?" with the
options **Stop Recording** and **Cancel**.

- Clicking **Stop Recording** closes the dialog and stops the recording as usual.
- Clicking **Cancel** closes the dialog and nothing else happens.

## Scope

Exactly one stop path gains a confirmation: the main **Stop Recording**
button in `ControlBar` (which also owns the ⌘. keyboard shortcut).

Unchanged, by design:

| Path | Why no confirmation |
|------|---------------------|
| Silence prompt "Stop & Save" (in-app) | Is already a confirmation |
| Notification "Stop Recording" action | Mirror of the silence prompt — already a confirmation |
| HTTP API `POST /sessions/stop` | Programmatic; a dialog would break automation (and `API/**` is frozen) |

## Design

### Presentation

A standard macOS alert (SwiftUI `.alert`) over the Tome window:

- **Title:** "Are you sure you want to stop recording?"
- **Buttons:**
  - **Cancel** — cancel role, **default button** (Return cancels).
  - **Stop Recording** — destructive role; closes the dialog and stops the session.

**As shipped (manual verification 2026-07-13):** Esc does nothing — SwiftUI
drops the cancel-role's implicit Esc equivalent when the button also carries
`.keyboardShortcut(.defaultAction)`, and a button holds only one shortcut.
Accepted deliberately: Return-cancels was the verified priority, and the
fallback (dropping the Return default to restore Esc) risked Return landing
on the destructive button. Bail-out paths are Return or clicking Cancel.

Cancel is deliberately the default: the entire premise of the feature is that
the stop was probably accidental, so the low-effort keys (Return, Esc) must
be the safe ones.

The alert does not pause anything — capture, transcription, the elapsed
timer, and the silence tracker all keep running until the user confirms.

### State model (testable unit)

The confirmation lifecycle lives in a small observable model rather than a
bare `@State` bool, so its semantics can be unit-tested in the existing
`TomeTests` target (no SwiftUI test harness exists in this repo):

`Tome/Sources/Tome/Views/StopConfirmationModel.swift`

```swift
@MainActor @Observable
final class StopConfirmationModel {
    var isPresented = false          // bound to the .alert
    var onConfirm: () -> Void = {}   // wired to stopSession() by ContentView

    func requestStop()      // main Stop button → isPresented = true
    func confirmStop()      // dialog "Stop Recording" → dismiss, fire onConfirm
    func cancelStop()       // dialog "Cancel" / Esc → dismiss, fire nothing
    func recordingDidEnd()  // session ended by another path → dismiss, fire nothing
}
```

### Wiring changes

**`ControlBar.swift`** — today the main Stop button and the silence prompt's
"Stop & Save" share one `onStop` closure. They split:

- Main Stop button → `onStopRequested` (new parameter) — ContentView passes
  `stopConfirmation.requestStop`.
- Silence prompt "Stop & Save" → keeps `onStop` — ContentView passes
  `stopSession` directly (that prompt is already a confirmation).

**`ContentView.swift`**:

- `@State private var stopConfirmation = StopConfirmationModel()`, with
  `onConfirm` wired to `stopSession()` in `.task`.
- `.alert("Are you sure you want to stop recording?",
  isPresented: <binding to stopConfirmation.isPresented>)` with the two
  buttons above. Cancel gets `.keyboardShortcut(.defaultAction)`; verify at
  build time that Esc still triggers the cancel-role button as well.
- Dismiss-on-external-end: in the existing
  `.onChange(of: transcriptionEngine?.isRunning ?? false)` handler, call
  `stopConfirmation.recordingDidEnd()` when `running` flips false, so a
  capture error / API stop / notification stop while the dialog is up
  withdraws it.

`stopSession()` itself is untouched. Its existing re-entrance guard
(`guard activeSessionType != nil`) already makes a stale confirm — e.g. the
API stopped the session in the instant before the user clicked "Stop
Recording" in the dialog — a harmless no-op.

### Alert-dismissal binding subtlety

SwiftUI sets the `isPresented` binding to `false` itself when any alert
button is tapped, *in addition to* running the button's action. The binding's
setter must therefore only forward the raw value
(`stopConfirmation.isPresented = newValue`); the cancel/confirm semantics
live exclusively in the button actions. Esc/click-away arrives as a plain
`set(false)` with no button action, which is exactly the cancel behavior
(nothing fires unless `confirmStop()` runs).

## Edge cases

- **Session ends while dialog is up** (capture error, API stop, notification
  stop): dialog auto-dismisses via `recordingDidEnd()`; nothing fires.
- **Race — session ends between dialog confirm and `stopSession()` running:**
  covered by `stopSession()`'s re-entrance guard; no double teardown, no
  duplicate `PostProcessingJob`.
- **Silence prompt visible, user clicks main Stop:** confirmation dialog
  appears on top; the silence prompt continues to obey its own rules
  underneath (it withdraws itself if audio resumes). Answering the dialog
  behaves normally either way.
- **⌘. while dialog is already up:** the alert is modal over the window, so
  the ControlBar shortcut can't re-fire; `requestStop()` is idempotent
  regardless.

## Testing

New `StopConfirmationModelTests.swift` in `TomeTests` (swift-testing, same
style as existing suites), pinning the model's semantics:

1. `requestStop()` presents the confirmation.
2. `confirmStop()` dismisses and fires `onConfirm` exactly once.
3. `cancelStop()` dismisses and fires nothing.
4. `recordingDidEnd()` while presented dismisses and fires nothing
   (external-stop withdrawal).
5. Full accidental-click sequence: request → cancel → request → confirm
   fires exactly once overall.

View wiring (button → model → alert) has no unit-test seam without a SwiftUI
harness; it is verified manually:

- Start a voice memo → click Stop → dialog appears; recording/timer still
  running behind it.
- Cancel → dialog closes, recording continues.
- Stop → Stop Recording → dialog closes, session finalizes as today.
- Esc and Return both cancel.
- ⌘. opens the same dialog.
- Silence prompt "Stop & Save" still stops immediately (no double dialog).
- `POST /sessions/stop` still stops immediately, including while the dialog
  is up (dialog withdraws).

Existing suite (94 tests) must stay green:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` from `Tome/`.

## Out of scope

- A "don't ask again" / confirmation-disable setting (not requested; YAGNI).
- Confirmation on recording *start* paths.
- Any change under `Tome/Sources/Tome/API/**` (frozen pending Nic/Dan discussion).
