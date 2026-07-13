# Stop-Recording Confirmation Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the main "Stop Recording" button behind an "Are you sure?" alert so an accidental click mid-meeting can't tear down a session.

**Architecture:** A tiny `@Observable @MainActor` model (`StopConfirmationModel`) owns the confirmation lifecycle so it's unit-testable; `ControlBar` splits its shared `onStop` closure so only the main button routes through the model; `ContentView` presents a SwiftUI `.alert` bound to the model and withdraws it if the session ends through another path. `stopSession()` is untouched.

**Tech Stack:** Swift / SwiftUI (macOS), swift-testing (`@Suite`/`@Test`/`#expect`), Swift Observation framework.

**Spec:** `docs/superpowers/specs/2026-07-13-stop-recording-confirmation-design.md`

## Global Constraints

- Work on branch `stop-recording-confirmation` (already created; baseline 94 tests green).
- Do NOT touch anything under `Tome/Sources/Tome/API/**` (frozen pending Nic/Dan discussion).
- Exact copy: alert title `Are you sure you want to stop recording?`; buttons `Stop Recording` (destructive) and `Cancel` (cancel role, **default button** — Return must cancel).
- Only the main Stop button confirms. The silence prompt's "Stop & Save", the notification stop action, and `POST /sessions/stop` keep stopping directly.
- All test/build commands run from `/Users/nic/programming/tome/Tome/` and need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (CommandLineTools lack the Testing framework).
- Match house style: doc comments explain *why* (see `AppServices.swift` for the pattern); closures on `@Observable` classes are `@ObservationIgnored`.

---

### Task 1: `StopConfirmationModel` + unit tests (TDD)

**Files:**
- Create: `Tome/Sources/Tome/Views/StopConfirmationModel.swift`
- Test: `Tome/Tests/TomeTests/StopConfirmationModelTests.swift`

**Interfaces:**
- Consumes: nothing (self-contained).
- Produces (Task 2 relies on these exact names):
  - `@Observable @MainActor final class StopConfirmationModel`
  - `var isPresented: Bool` (read/write — SwiftUI's alert binding writes it)
  - `@ObservationIgnored var onConfirm: () -> Void` (default `{}`)
  - `func requestStop()`, `func confirmStop()`, `func cancelStop()`, `func recordingDidEnd()`

- [ ] **Step 1: Write the failing tests**

Create `Tome/Tests/TomeTests/StopConfirmationModelTests.swift`:

```swift
import Testing
@testable import Tome

@Suite @MainActor struct StopConfirmationModelTests {

    @Test func requestPresentsTheConfirmation() {
        let model = StopConfirmationModel()
        #expect(!model.isPresented)
        model.requestStop()
        #expect(model.isPresented)
    }

    @Test func confirmDismissesAndFiresStopExactlyOnce() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        model.confirmStop()
        #expect(!model.isPresented)
        #expect(stops == 1)
    }

    @Test func cancelDismissesWithoutFiring() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        model.cancelStop()
        #expect(!model.isPresented)
        #expect(stops == 0)
    }

    @Test func externalRecordingEndWithdrawsTheDialogWithoutFiring() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        // Session ended by a capture error / API stop / notification stop
        // while the dialog was up — it must withdraw without stopping again.
        model.recordingDidEnd()
        #expect(!model.isPresented)
        #expect(stops == 0)
    }

    @Test func accidentalClickThenRealStopFiresExactlyOnce() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        // The motivating scenario: accidental click mid-meeting → Cancel,
        // then the real stop at meeting end → Stop Recording.
        model.requestStop()
        model.cancelStop()
        model.requestStop()
        model.confirmStop()
        #expect(stops == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/nic/programming/tome/Tome
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StopConfirmationModelTests
```

Expected: **build failure** — `error: cannot find 'StopConfirmationModel' in scope`. (swift-testing compiles the whole test target; the missing type is the red step.)

- [ ] **Step 3: Write the implementation**

Create `Tome/Sources/Tome/Views/StopConfirmationModel.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/nic/programming/tome/Tome
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StopConfirmationModelTests
```

Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/nic/programming/tome
git add Tome/Sources/Tome/Views/StopConfirmationModel.swift Tome/Tests/TomeTests/StopConfirmationModelTests.swift
git commit -m "feat: add StopConfirmationModel — testable stop-confirmation lifecycle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire the confirmation into ControlBar + ContentView

**Files:**
- Modify: `Tome/Sources/Tome/Views/ControlBar.swift` (callback params ~line 40, main Stop button ~line 84)
- Modify: `Tome/Sources/Tome/Views/ContentView.swift` (state ~line 31, ControlBar call ~line 106, alert after `.preferredColorScheme` ~line 115, `.onChange(of: isRunning)` ~line 130, boot `.task` wiring ~line 210)

**Interfaces:**
- Consumes (from Task 1): `StopConfirmationModel` — `isPresented`, `onConfirm`, `requestStop()`, `confirmStop()`, `cancelStop()`, `recordingDidEnd()`.
- Produces: `ControlBar` gains `let onStopRequested: () -> Void` (declared immediately above the existing `onStop`); existing `onStop` is now the silence prompt's direct-stop path only.

There is no SwiftUI view test harness in this repo — this task's safety net is the compile, the full existing suite, and Task 3's manual checklist. All view wiring lands in one task so the app never has a Stop button wired to a flag nothing reads.

- [ ] **Step 1: Split the stop callback in ControlBar.swift**

In the parameter block, replace:

```swift
    let onStop: () -> Void
```

with:

```swift
    /// Main Stop button — requests the "Are you sure?" confirmation
    /// (StopConfirmationModel) instead of stopping directly.
    let onStopRequested: () -> Void
    /// Direct stop, no second confirmation — used only by the silence
    /// prompt's "Stop & Save", which is already a confirmation.
    let onStop: () -> Void
```

Then change the main Stop button (the `if isRecording` branch — NOT the one inside `silenceStopPrompt`) from:

```swift
                Button(action: onStop) {
                    HStack(spacing: 10) {
                        PulsingDot(size: 6)
```

to:

```swift
                Button(action: onStopRequested) {
                    HStack(spacing: 10) {
                        PulsingDot(size: 6)
```

The `Button(action: onStop)` inside `silenceStopPrompt` ("Stop & Save") stays exactly as is.

- [ ] **Step 2: Add the model + wiring in ContentView.swift**

(a) With the other `@State` declarations (after `silencePromptActive`, ~line 31), add:

```swift
    /// Confirmation gate for the main Stop button. `onConfirm` is wired to
    /// `stopSession()` in the boot task; the silence prompt, notification
    /// action, and HTTP API bypass it (see StopConfirmationModel).
    @State private var stopConfirmation = StopConfirmationModel()
```

(b) In the `ControlBar(...)` call, insert the new argument directly above `onStop:` (order must match the declaration order in ControlBar):

```swift
                onStopRequested: { stopConfirmation.requestStop() },
                onStop: stopSession,
```

(c) Directly after `.preferredColorScheme(.dark)`, add the alert:

```swift
        .alert(
            "Are you sure you want to stop recording?",
            isPresented: Binding(
                get: { stopConfirmation.isPresented },
                set: { stopConfirmation.isPresented = $0 }
            )
        ) {
            // Cancel is the default (Return): the premise of this dialog is
            // that the stop was probably accidental, so the low-effort keys
            // must be the safe ones. Esc also cancels via the .cancel role.
            Button("Cancel", role: .cancel) { stopConfirmation.cancelStop() }
                .keyboardShortcut(.defaultAction)
            Button("Stop Recording", role: .destructive) { stopConfirmation.confirmStop() }
        }
```

(d) In the existing isRunning mirror, add the withdrawal (the handler becomes):

```swift
        .onChange(of: transcriptionEngine?.isRunning ?? false) { _, running in
            // Mirror live recording state into AppServices so the MenuBarExtra
            // scene (which can't see the engine) can show a recording indicator.
            services.isRecording = running
            // Session ended through another path (capture error, API stop,
            // notification stop) — withdraw a pending stop confirmation.
            if !running { stopConfirmation.recordingDidEnd() }
        }
```

(e) In the boot `.task`, next to the `NotificationPresenter.shared.silenceStopAction` wiring (~line 210), add:

```swift
            // Dialog "Stop Recording" → the real teardown. stopSession()'s
            // re-entrance guard makes a stale confirm (session already ended
            // by the API/notification in the same instant) a harmless no-op.
            stopConfirmation.onConfirm = { stopSession() }
```

- [ ] **Step 3: Build and run the full suite**

```bash
cd /Users/nic/programming/tome/Tome
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: `Test run with 99 tests in 18 suites passed` (94 baseline + 5 from Task 1). Zero warnings introduced in the two modified files.

- [ ] **Step 4: Commit**

```bash
cd /Users/nic/programming/tome
git add Tome/Sources/Tome/Views/ControlBar.swift Tome/Sources/Tome/Views/ContentView.swift
git commit -m "feat: confirm before stopping a recording from the main Stop button

Accidental clicks mid-meeting were irreversibly ending sessions. The main
Stop button (and its Cmd-. shortcut) now presents 'Are you sure you want
to stop recording?' with Cancel as the default; the silence prompt,
notification action, and HTTP API still stop directly.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Manual verification (human at the wheel)

**Files:** none (verification only; fix-forward if a check fails).

The view wiring has no unit-test seam, so this checklist is the acceptance gate. Launch a dev build:

```bash
cd /Users/nic/programming/tome/Tome
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Tome
```

(or the usual app-bundle path via `scripts/build_swift_app.sh` if `swift run` misbehaves for GUI features).

- [ ] Start a Voice Memo → click **Stop Recording** → dialog appears with title "Are you sure you want to stop recording?" and buttons Cancel / Stop Recording; the elapsed timer keeps counting behind it.
- [ ] Click **Cancel** → dialog closes, recording continues, transcript still flowing.
- [ ] Press **⌘.** → dialog appears; press **Return** → cancels (Cancel is default).
- [ ] Press **⌘.** → dialog appears; press **Esc** → cancels. *If Esc does nothing (SwiftUI may drop the implicit Esc binding when Cancel also carries `.defaultAction`): remove `.keyboardShortcut(.defaultAction)` from Cancel, rebuild, and re-verify that Return no longer stops the recording (acceptable fallback: no default button, Esc cancels) — then update the spec's Presentation section to match what shipped.*
- [ ] Click **Stop Recording** in the dialog → dialog closes, session finalizes exactly as before (post-processing runs, note saved, banner appears).
- [ ] Trigger the silence prompt (Settings → set silence auto-stop low, stay quiet) → **Stop & Save** stops immediately, NO second dialog.
- [ ] With the dialog open, `curl -X POST http://localhost:<port>/sessions/stop` → session stops AND the dialog withdraws itself; clicking nothing else, app is idle and consistent.
- [ ] Verify **⌘R / ⌘⇧R** still start sessions (untouched, regression check).

Record the outcome (all boxes, plus which Esc branch applied) in the final report to the user. No commit from this task unless the Esc fallback was needed (then commit the one-line change with message `fix: drop default-action shortcut on Cancel — Esc binding wins`).

---

## Self-Review (completed)

- **Spec coverage:** presentation/copy → Task 2c; Cancel-default → Task 2c + Task 3 keyboard checks; callback split → Task 2 Step 1; testable model + 5 named tests → Task 1; dismiss-on-external-end → Task 2d + Task 3 curl check; binding subtlety → Task 2c comment + model doc comment; unchanged paths → Task 2 Step 1 (silence), Task 3 checks (notification path shares silence-prompt guard; API untouched); out-of-scope items → no tasks touch them. No gaps.
- **Placeholder scan:** none — every code step shows full code, every command has expected output.
- **Type consistency:** `StopConfirmationModel` member names identical across Task 1 (definition), Task 2 (usage): `isPresented`, `onConfirm`, `requestStop()`, `confirmStop()`, `cancelStop()`, `recordingDidEnd()`. `onStopRequested` matches between ControlBar declaration and ContentView call site.
