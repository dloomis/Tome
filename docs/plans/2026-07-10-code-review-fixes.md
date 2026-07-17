# Execution Plan — Code-Review Fixes for `fix-system-audio-per-app-capture`

**Target branch:** `fix-system-audio-per-app-capture` (commits `9a0f247` capture fix, `ad5a957` discard feature)
**Origin:** multi-agent code review of `HEAD~2..HEAD` on 2026-07-10. 8 findings survived adversarial verification (7 CONFIRMED, 1 PLAUSIBLE-adjacent). Line numbers below were correct at plan time — re-locate by symbol name if the file has drifted.

**Build/verify commands** (all from `Tome/` where Package.swift lives):

```bash
/Library/Developer/CommandLineTools/usr/bin/swift build              # app target
/Library/Developer/CommandLineTools/usr/bin/swift build --build-tests # includes TomeTests
/Library/Developer/CommandLineTools/usr/bin/swift test               # after Task 2 lands
```

Rules of the road: run `swift build --build-tests` after every task; commit per task (or per phase) with descriptive messages. Do NOT push or open a PR unless asked.

---

## Phase 1 — Correctness (must fix)

### Task 1 — Fix the `restartSystemAudioLeg` vs `stop()` race  **[CONFIRMED, most severe]**

**File:** `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (`restartSystemAudioLeg` ~line 398, `stop()` ~line 711)

**Bug (verified interleaving):** Both methods are `@MainActor`; they interleave at suspension points. `stop()` sets `isRunning = false` only at its LAST line — after `await drainTranscriberTasks()` (up to 15s awaiting `micTask`). Meanwhile the startup gate's `restartSystemAudioLeg`:
1. passes its `guard isRunning` checks (still true — stop hasn't finished),
2. reads `activeRecordingContext` AFTER stop() already nil'd it near its top → `bufferStream(recordingContext: nil)` creates a sidecar-less `$TMPDIR` WAV (leaked, invisible to the orphan scanner),
3. calls `spinUpSystemTranscription`, assigning a NEW detached `sysTask` created after `drainTranscriberTasks` snapshotted `[micTask, sysTask]` — so it is never drained or cancelled. Net: SCStream keeps capturing after Stop and the zombie `.them` transcriber appends stray utterances into the reused `transcriptStore` (pollutes the NEXT session's transcript).
`stop()`'s `sysStartupGateTask?.cancel()` is inert once the rebuild is past its `Task.isCancelled` check — neither `systemCapture.stop()` nor `bufferStream` observes cancellation.

**Fix (do both):**
1. Add a monotonically-increasing session generation counter (e.g. `private var sessionGeneration = 0`, incremented at the top of `start()` AND at the top of `stop()` before any await). In `restartSystemAudioLeg`, capture the generation on entry and re-check `generation == sessionGeneration && isRunning` after EVERY `await` (after `systemCapture.stop()`, after `bufferStream`). Bail + `await systemCapture.stop()` to unwind if stale. (A `isStopping` boolean set at the top of `stop()` also works; the generation token additionally protects against stop-then-quick-restart.)
2. In `stop()`, if a rebuilt `sysTask` could still exist, cancel it explicitly: `sysTask?.cancel()` before `sysTask = nil` (line ~736). Today stop only drops the reference.

**Verify:** `swift build`. Then reason through the interleaving again (or add a unit test if a seam exists): gate fires → user stops during rebuild → assert no new sysTask survives and `systemCapture` is stopped. Grep that every `await` inside `restartSystemAudioLeg` is followed by a staleness re-check.

---

### Task 2 — Repair the broken test target  **[CONFIRMED — `swift test` does not compile]**

**File:** `Tome/Tests/TomeTests/PostProcessingJobTests.swift` (lines 64, 103, 172, 174)

**Bug:** Commit `ad5a957` changed `PostProcessingJob.run()` from returning `URL` to `JobOutcome` (`case saved(URL)` / `case discarded(path: URL, durationSeconds: Int)`), but the tests still do `saved.path`, `saved.lastPathComponent`, and pass the outcome where a `URL` is expected. Compiler errors:

```
PostProcessingJobTests.swift:64:62: error: value of type 'PostProcessingJob.JobOutcome' has no member 'path'
PostProcessingJobTests.swift:103:40: error: cannot convert value of type 'PostProcessingJob.JobOutcome' to expected argument type 'URL'
PostProcessingJobTests.swift:172:23: error: value of type 'PostProcessingJob.JobOutcome' has no member 'lastPathComponent'
PostProcessingJobTests.swift:174:49: error: value of type 'PostProcessingJob.JobOutcome' has no member 'path'
```

**Fix:**
1. Update the tests to unwrap the outcome, e.g. a small helper in the test file:
   ```swift
   func requireSaved(_ outcome: PostProcessingJob.JobOutcome) throws -> URL {
       guard case .saved(let url) = outcome else { throw ... /* XCTFail-style */ }
       return url
   }
   ```
2. ADD coverage for the new discard behavior: a call-capture job under the threshold returns `.discarded` and deletes the transcript + capture files; a voice-memo job is never discarded; threshold boundary (exactly N seconds → discarded, N+1 → saved).
3. Also fix the stale line in `/Users/dloomis/Projects/Tome/CLAUDE.md`: "There is no test suite and no linter configured." is false — `Package.swift` declares a `TomeTests` target with 20+ test files. Replace with the actual `swift test` invocation guidance.

**Verify:** `swift test` passes.

---

### Task 3 — Give discards an auth-independent in-app signal  **[CONFIRMED]**

**Files:** `Tome/Sources/Tome/Views/ContentView.swift` (discard `onChange` handler, ~line 317), `Tome/Sources/Tome/App/NotificationPresenter.swift` (`postDiscard`, ~line 182)

**Bug:** When notification permission is denied, a discarded short meeting produces ZERO user feedback: the handler deliberately shows no banner ("There's no file to open, so no banner") and `postDiscard` bails at `guard authorized`. That recreates the exact silent-vanish the feature's own doc comment says it exists to prevent. Contrast `handleJobCompleted`, which sets the `savedFileURL` in-app banner independent of notification auth.

**Fix:** Show an in-app, auth-independent signal in the discard `onChange` handler — a transient status/banner ("Short recording discarded (18s) — under your discard threshold") using whatever lightweight mechanism fits the existing banner UI (a variant of the save banner without the open-file affordance is fine). Keep the notification too.

**Verify:** `swift build`; trace that the new UI state is set unconditionally in the handler, before/independent of the `postDiscard` Task.

---

### Task 4 — Fix the startup-gate/watchdog alarm delay + silent-rebuild blind spot  **[CONFIRMED]**

**File:** `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (`restartSystemAudioLeg` ~406, comment at ~364); `Tome/Sources/Tome/Audio/SystemAudioCapture.swift` (`bufferStream` seeds `_lastSampleTime = Date()`)

**Bug (verified timeline):** For a leg that NEVER delivers: pre-gate, the watchdog alarmed at ≈t=20s (5s ticks, 15s threshold, seed at t=0). The gate fires at t=8 and its rebuild calls `bufferStream`, which RE-SEEDS `_lastSampleTime` — pushing the first `gap > 15` tick to ≈t=25. The gate therefore DELAYS the user-facing "System audio capture stalled" alarm, contradicting its own comment ("collapsing the wait before the 15s stall watchdog"). Additionally, `restartSystemAudioLeg`'s `catch` posts an alert only when `bufferStream` THROWS — a rebuild that succeeds but stays silent posts nothing.

**Fix:** After a successful rebuild, schedule a short one-shot grace check (~5s): if `systemCapture.firstSampleTime` is still nil, post the "System audio isn't being captured — recording mic only." alert directly (same `lastError` + `postCaptureStall(leg: "System audio", ...)` as the catch path) instead of waiting for the re-seeded watchdog window. Update the comment at `armSystemStartupDeliveryGate` to describe the real timeline. This check must respect the Task-1 generation guard.

**Verify:** `swift build`; walk the never-delivers timeline: gate t=8 → rebuild → grace check t≈13 → alert. Confirm no alert when first sample arrives before the grace check.

---

### Task 5 — Auto-rebuild the system leg on mid-session stalls  **[CONFIRMED gap]**

**File:** `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (`startCaptureWatchdog`, sysEvent branch ~line 885)

**Bug:** The watchdog auto-restarts only the mic (`restartMic` on stall/down, with re-attempt cadence and surrender logic). A system leg that delivers then stalls mid-meeting (captured app quits, SCK pause, permission revoked) gets only `handleStallEvent` (banner + `lastError`) — "Them" stays dead for the rest of the call. The startup gate only covers `firstSampleTime == nil` at t=8. `restartSystemAudioLeg` now exists, so the wiring is small.

**Fix:** In the watchdog's `sysEvent` handling, on `.stalled` also attempt `restartSystemAudioLeg()` with the same discipline the mic side uses: re-attempt at most every 3 stalled ticks (`stalledTicksSinceRestart`-style counter for the sys leg), and keep posting the stall banner. Reuse — do not duplicate — the existing `restartSystemAudioLeg` (which after Task 1 is race-safe and after Task 4 self-alarms on silent rebuilds). Beware: each rebuild re-seeds the watchdog clock (Task 4's finding), so keep the sys stall latch (`CaptureStallDetector.isStalled`) driving the retry cadence rather than fresh stall events.

**Verify:** `swift build`; trace: sysEvent `.stalled` → banner + rebuild attempt; still-stalled 3 ticks later → another attempt; resumed → latch clears, banner clears.

---

## Phase 2 — Improvements (should fix)

### Task 6 — Exclude known noise apps from display-wide capture  **[CONFIRMED, cheap mitigation]**

**File:** `Tome/Sources/Tome/Audio/SystemAudioCapture.swift` (`bufferStream`, filter at ~line 73)

**Issue:** Display-wide capture (the deliberate fix for the Teams helper-process silence) now feeds ALL app audio — music, videos, chimes — through VAD+ASR as speaker `.them`, polluting transcripts and burning inference on background audio.

**Fix:** Use `SCContentFilter(display:excludingApplications:exceptingWindows:)` with a denylist of known noise-app bundle IDs found in `content.applications` (e.g. `com.apple.Music`, `com.spotify.client`, and Tome itself is already excluded via `excludesCurrentProcessAudio`). Exclusion-by-app is safe where inclusion wasn't: media apps render their own audio, so excluding them cannot drop conferencing-helper audio. Keep the denylist small and conservative; document why inclusion filtering must never come back (see the comment block already at the top of `bufferStream`).

**Verify:** `swift build`; confirm the filter still captures a non-denylisted test app's audio (manual smoke: play a YouTube video in Safari — should still be captured; play Music.app — should not).

### Task 7 — Stop over-fetching shareable content  **[CONFIRMED]**

**File:** `Tome/Sources/Tome/Audio/SystemAudioCapture.swift` (~line 67)

**Issue:** `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` enumerates every window (including off-screen) via WindowServer IPC on every session start and every gate rebuild. After the per-app branch removal, `content.displays.first` was the only remaining consumer — but Task 6 re-introduces a use of `content.applications` for the denylist.

**Fix:** Pass `onScreenWindowsOnly: true` (and `excludingDesktopWindows: true`) — `displays` and `applications` are populated independently of window filtering; only the `windows` array shrinks, and nothing reads it.

**Verify:** `swift build`; system capture still starts (displays non-empty) and the Task-6 denylist still matches running apps.

### Task 8 — Route the system gate's decision through the shared pure predicate  **[cleanup, flagged by 3 angles]**

**File:** `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (`handleSystemStartupGate` ~line 438; mic predicate `shouldForceStartupRestart` ~line 429)

**Issue:** `handleSystemStartupGate` re-implements inline the exact boolean the mic side extracted into the pure, unit-testable `nonisolated static func shouldForceStartupRestart(firstSampleAt:isRunning:alreadyFired:rebuildInFlight:)`. Two copies of one policy will drift (the mic version has a `rebuildInFlight` guard; the sys copy doesn't), and only the mic version is testable.

**Fix:** Replace the inline guards with `Self.shouldForceStartupRestart(firstSampleAt: systemCapture.firstSampleTime, isRunning: isRunning, alreadyFired: sysStartupGateFired, rebuildInFlight: false)`. If Task 5 introduces a sys-rebuild-in-flight concept, thread it into the `rebuildInFlight` argument. Add/extend the predicate's unit tests to cover the system-leg call pattern.

### Task 9 — Small confirmed cleanups (batch into one commit)

1. **`NotificationPresenter.postDiscard`** (~line 182): the `sessionType` parameter is never used (title/body use only `durationSeconds`). Either use it in the copy ("short meeting" vs "short memo" — note voice memos are never discarded, so probably just DROP the param) and remove the field from `PostProcessingQueue.JobDiscard` if nothing else reads it.
2. **`PostProcessingJob.Phase.discarded(URL)`** (~line 18): the associated URL points at a just-deleted file and no consumer reads it (`PostProcessingQueue` matches `JobOutcome`, not `Phase`; APIServer never inspects `.discarded`). Make it payload-less: `case discarded`.
3. **CLAUDE.md test-suite line** — covered in Task 2 step 3; skip here if already done.

**Verify:** `swift build --build-tests && swift test`.

---

## Explicitly out of scope (reviewed, verified, deliberately deferred)

- **Discard decision inside `PostProcessingJob` vs at `stopSession`** [PLAUSIBLE]: moving it earlier only shrinks the post-stop lingering window; the live note is written into the (synced) vault from `startSession` onward regardless. Revisit only if backlog-lingering is observed in practice.
- **SessionStore `<sessionId>.jsonl` not deleted on discard**: pre-existing leak (normal completion doesn't delete it either). Fix belongs in a general journal-cleanup pass, not this branch.
- **`sysStartupGateFired` arguably dead state** (gate armed exactly once): keep it — Task 5 may re-arm rebuild attempts, and the flag matches the mic idiom.
- **Notification boilerplate duplication in NotificationPresenter** (4th verbatim copy): fine to fold into a `postFireAndForget(title:body:)` helper if touching the file anyway (Task 9.1), not otherwise.
- **`hasDiarizationCompleted` staleness after a discard** (API flag asymmetry): negligible impact — the transcript is gone; note only if the API layer gets reworked.

## Suggested commit sequence

1. `Fix stop-race in system-audio startup gate rebuild` (Task 1)
2. `Update PostProcessingJob tests for JobOutcome; add discard coverage; fix stale CLAUDE.md test note` (Task 2)
3. `Show in-app signal when a short meeting is discarded` (Task 3)
4. `Alarm directly when a rebuilt system leg stays silent` (Task 4)
5. `Auto-rebuild system-audio leg on mid-session stalls` (Task 5)
6. `Exclude known media apps from display-wide capture; trim shareable-content query` (Tasks 6+7)
7. `Reuse shouldForceStartupRestart for the system gate; misc cleanups` (Tasks 8+9)

Each commit: `swift build --build-tests` green; from commit 2 onward `swift test` green. End messages with `Co-Authored-By:` per session convention.
