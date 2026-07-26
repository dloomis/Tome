# Main-Thread Capture Bind Freezes the App — Off-Main-Actor Audio Bring-Up

**Date:** 2026-07-25
**Status:** Implemented 2026-07-25 (`HALQueue.swift` serial executor + wedge
latch; async `MicCapture.bufferStream`/`stop` with 5s detach-deadline;
timed-out engines parked for process lifetime; Part C policies — mic timeout
fails the start with no default-cascade, device timeout falls back to SCK;
Part D — deferred `AppSettings` legacy migration, debounced off-main Settings
enumeration. Open questions resolved as proposed: 5s deadline, no retry,
global latch, one shared executor. Manual AC on the repro machine still owed.)
**Type:** Defect (availability) + architectural hardening
**Prereq reading:** `2026-07-25-mixer-device-system-audio-capture.md` (the
device-backed system leg, which doubles the number of HAL binds per session);
`MicCapture.swift`'s incident comments (AirPods HFP flip, `retire()`
use-after-free, tap format-mismatch exception) — this rework must preserve
every one of those guards.

## Incident (observed 2026-07-25, this machine)

Tome hung with a spinning beach ball, a stale "Loading VAD model" status, and
"Not Responding" in Activity Monitor. It was force-quit. There is **no crash
report** and `~/Library/Application Support/Tome/last-crash.log` is 0 bytes
(truncated at launch, never written) — consistent with a hang plus SIGKILL,
not a fatal signal.

Timeline from the unified log:

| Time | Event |
|---|---|
| 19:00:46 | Call capture starts in **device mode**: mic binds device 90 `Elgato Wave Link Mic Only`, system leg binds device 100 `Elgato Wave Link Transcriber`. Both reach `[MIC-8] engine started successfully`. |
| 19:01:01 | Two `[MIC-RETIRE]` (one per leg) — the 15s engine parking drains normally. |
| 19:01:28 | Session stops; `PostProcessingJob` completes normally. |
| 19:01:23 | **Wave Link launches** (`launchd` spawns `WaveLinkMacOS[34238]`). |
| 19:01:28+ | Wave Link initializes its audio graph — thousands of `AudioConverter … in-process GetProperty call returned 1886547824` per second. |
| 19:01:37.055 | New session. `[MIC-1] bufferStream deviceID=90`. |
| 19:01:37.080 | `[MIC-2] setInputDevice device 90 "Elgato Wave Link Mic Only" status=0`. |
| 19:01:37.087 | `[MIC-7] engine prepared, starting...` |
| — | **`[MIC-8]` never appears.** `AVAudioEngine.start()` did not return. |
| 19:01:53 | `[MIC-RETIRE]` — the detached 15s parking task still fires; it is the only thing in the process still making progress. |

The trigger is **binding an input device belonging to a virtual-audio driver
while that driver's host app is initializing**. Wave Link had been launched
14 seconds earlier and was still reconfiguring.

### Second occurrence (2026-07-25 20:13, live stack captured)

Reproduced during manual AC of the digital-silence fix — and this time
`sample` was run against the live hang, upgrading the mechanism from inferred
to observed. Main thread (2527/2527 samples):

```
TranscriptionEngine.start (TranscriptionEngine.swift:311)
→ MicCapture.bufferStream (MicCapture.swift:504, closure at :508, inside TomeCatchObjCException)
→ -[AVAudioEngine startAndReturnError:]
→ AudioOutputUnitStart → HAL_HardwarePlugIn_DeviceStart
→ HALC_ProxyIOContext::StartIOProc → HALB_IOThread::StartAndWaitForState
→ HALB_Guard::WaitFor → _pthread_cond_wait / __psynch_mutexwait   ← wedged
```

Same signature ([MIC-7] at 20:13:07.237, no [MIC-8]), same device class
(device 92 `Elgato Wave Link Mic Only`). **Materially new: Wave Link had been
running since before Tome launched** — no relaunch, no reconfiguration window.
The "host app is initializing" framing above is a special case; the driver can
wedge `StartIO` at any time. That removes any hope of avoiding the hang by
timing heuristics ("don't bind within Ns of mixer launch") and strengthens the
case for Part B's deadline as the only general defense. Force-quit + relaunch
recovered cleanly (orphan scan, API healthy), confirming the interim
mitigation. Sample retained from the session scratchpad as
`tome_hang_sample.txt` if needed before it expires.

## Mechanism

`MicCapture.bufferStream` performs its entire bring-up **synchronously inside
the `AsyncStream` builder closure**, which runs on the caller's thread — and
every caller is `@MainActor` (`TranscriptionEngine`). The blocking sequence:

1. old engine teardown — `removeTap` + `engine.stop()`
2. `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`
3. `inputNode.inputFormat(forBus: 0)` (HAL round trip)
4. `installTap`
5. `AudioObjectAddPropertyListenerBlock` ×2 (HAL fast path)
6. **`engine.prepare()` / `engine.start()`** ← where it wedged

All six are HAL calls that can block indefinitely on a misbehaving driver.
When they block on the main actor, the app is dead: SwiftUI stops rendering
(hence the stale status string — later `assetStatus` assignments ran but were
never drawn), and **every recovery mechanism Tome has is also main-actor
bound** — the 3s startup-delivery gate, the 15s stall watchdog, the debounced
config-change rebuild, the digital-silence checks. The design assumes a
responsive main actor to rescue a dead capture; it cannot rescue a main actor
that is itself blocked inside the capture.

`MicCapture`'s own doc comments codify the current model ("Only touched from
the main actor (TranscriptionEngine), like the rest of this class's mutable
state"). That model is what has to change.

### Attribution

**Not caused by the mixer-device feature.** The wedge is on the *mic* leg,
which has bound on the main thread since the beginning; automatic mode would
have frozen identically at 19:01:37.

**But the feature increases exposure.** Device mode performs two HAL binds per
session instead of one, and both target third-party virtual devices — the
class of device most likely to block. It also makes "Wave Link is running" a
*prerequisite* of the happy path, so users will now routinely launch Wave Link
and start recording moments later: the exact trigger.

### Blast radius — every main-actor HAL call

Beyond `bufferStream`, the same freeze is reachable from:

- **`MicCapture.stop()`** (9 call sites) — `removeTap` + `engine.stop()` on a
  wedged device blocks just as hard. Reached from `engine.stop()`,
  `restartMic`, and both unwind paths in `start()`.
- **Device enumeration statics** — `availableInputDevices()`,
  `deviceID(forUID:)`, `deviceName(for:)`, `defaultInputDeviceID()` all issue
  synchronous `AudioObjectGetPropertyData`. Called from `start()`,
  `restartMic`, `bringUpSystemLeg`, `reportMicFallback`, both silence checks,
  and the fallback predicate — ~15 main-actor sites.
- **`AppSettings.init`** — `migratedInputSelection` resolves device names at
  construction, i.e. **during app launch, before any window exists**. A wedged
  HAL here means Tome never finishes launching.
- **`SettingsView.InputDeviceList.refresh()`** — `@MainActor`, and re-fires on
  every `kAudioHardwarePropertyDevices` change. A driver initializing emits a
  storm of those; the Settings window enumerates devices on each one.

Any real fix has to cover these, not just `engine.start()`.

## Design

### Part A — One serial HAL executor, off the main actor

Introduce a single dedicated serial execution context (a global `actor` with a
custom executor, or one `DispatchQueue` wrapped behind an actor) that owns
**all** blocking CoreAudio/AVAudioEngine work: bring-up, teardown, listener
registration, and device enumeration.

Serial, and shared by both legs, deliberately:

- Two `MicCapture` instances binding devices from the same driver
  concurrently is a new condition introduced by device mode and is not known
  to be safe; serializing removes the question.
- It gives one place to observe "the HAL is wedged" — see Part C.

Trade-off to accept explicitly: a wedge now blocks *both* legs' audio
operations instead of the whole app. The UI, the transcript writer, the
post-processing queue and quit all stay responsive. That is the whole point.

`MicCapture`'s mutable state moves from "main-actor only" to "HAL-executor
only". The two plain (non-lock) properties — `engine` and `_halListener` —
follow it; the `OSAllocatedUnfairLock` fields already tolerate any thread and
keep serving readers (watchdog, gates, UI meter) unchanged.

### Part B — `bufferStream` becomes async, with a bind deadline

Today `bufferStream` returns the stream synchronously and reports setup
failure out-of-band via `captureError`, which every caller reads on the very
next line. That contract cannot survive the move. Proposed shape:

```swift
func bufferStream(deviceID: AudioDeviceID?, recordOutputURL: URL?)
    async -> Result<AsyncStream<AVAudioPCMBuffer>, CaptureBindError>
```

Three call sites update: `start()` (mic), `restartMic()`,
`startDeviceSystemLeg()`. All three are already in async or trivially
async-able contexts.

**The deadline is a detach, not a cancel.** A HAL call blocked in the kernel
cannot be interrupted — `Task.cancel()` will not unstick
`AVAudioEngine.start()`. So a bind that exceeds the deadline means: stop
waiting, report `.timedOut`, and leave the blocked work running on the HAL
executor until the driver releases it. Consequences to design for:

- The abandoned engine must never be touched again. Extend the existing
  `retire()` discipline (which exists for precisely this class of hazard) to
  cover timed-out engines, with no 15s release — hold them for the process
  lifetime rather than risk deallocating an object a wedged HAL still
  references.
- The HAL executor is occupied until the driver unblocks, so subsequent binds
  queue behind it. They must fail fast on the same deadline rather than
  stacking unbounded — a simple "HAL is wedged" latch (Part C) is cheaper than
  a per-call timer.

Proposed deadline: **5s**. Rationale: a healthy bind on this machine takes
25–30 ms (`MIC-1` → `MIC-8`); the AirPods cold-start startup gate already
waits 3s for first *delivery*. 5s is two orders of magnitude above normal and
still well inside a user's patience for "Start" to do something.

### Part C — What a timed-out bind does

Open decision, flagged rather than assumed (see Open questions):

- **Mic leg.** The existing bind-failure path falls back to the system default
  input. That is wrong here: when the wedge is driver-wide the system default
  *is* the wedged device (it was device 90 in this incident), so the fallback
  re-queues behind the same block. Proposal: on `.timedOut`, do **not**
  cascade — fail the session start with a specific, actionable error
  ("Audio device '<name>' isn't responding — it may still be starting up. Try
  again in a few seconds.") and let `ContentView.rollbackFailedStart` unwind.
- **System leg (device mode).** Fail the leg, surface via the existing
  `systemSourceFallbackMessage`, and fall back to SCK — which touches no HAL
  input device and is therefore unaffected by the wedge. This one is clean.
- **Wedge latch.** While a timed-out operation is still outstanding, further
  binds fail immediately with the same error instead of queueing. Cleared when
  the abandoned operation finally returns (the executor can observe this).

### Part D — Device enumeration and launch safety

- Route the four enumeration statics through the same executor and make them
  async, or keep sync variants for genuinely non-blocking callers only if that
  can be proven (it probably cannot — any `AudioObjectGetPropertyData` can
  block).
- `AppSettings.init` must stop resolving device names synchronously. The
  migration only needs a name for display; resolve it lazily after launch, or
  accept an empty name and fill it in when the Settings picker first
  enumerates. **A wedged HAL must never be able to prevent app launch.**
- `InputDeviceList.refresh()` should debounce the
  `kAudioHardwarePropertyDevices` storm a driver emits while initializing
  (~1s coalescing window, same shape as `scheduleMicRebuild`'s debounce).

## Acceptance criteria

1. **Repro is fixed:** launch Wave Link, then start a Call Capture within a
   few seconds of it appearing. The UI stays responsive throughout. Either the
   session starts normally, or it fails within ~5s with the device-not-
   responding error — never a beach ball.
2. The app remains responsive (window draggable, menu bar live, Cmd-Q works,
   the post-processing queue keeps draining) while a HAL bind is blocked.
3. App launch completes with a wedged/initializing virtual driver present.
4. The Settings ▸ Audio device list does not freeze the Settings window while
   a driver is enumerating.
5. **No regression in the incident-hardened behaviors:** fresh engine per
   capture; retire-don't-deallocate; HAL fast-path listener registered before
   `start()`; `TomeCatchObjCException` still wrapping tap install / start /
   teardown; append-reopen retention across a mid-session rebuild;
   AirPods A2DP→HFP cold-start recovery.
6. Every existing gate/watchdog behaves as before on a *healthy* device — the
   3s startup gate, 15s stall watchdog, 1.2s config-change debounce with its
   ground-truth and storm gates, and both digital-silence checks.
7. `swift test` green.

## Test plan

**Unit (Swift Testing, pure):**

- Bind-outcome decision: (elapsed, deadline, wedgeLatch) → `{bound, timedOut,
  failFast}`.
- Timed-out mic bind does **not** produce a fallback-to-default attempt
  (guarding the cascade described in Part C).
- Timed-out device bind resolves to `sckFallback(.bindFailed)` and produces
  the existing fallback message.
- Enumeration-storm debounce: N device-change events inside the window → one
  refresh.

**Fault injection:** a test double for the HAL executor whose "bind" sleeps
past the deadline, so the timeout path is exercised without a real wedged
driver. This is the only way to get this failure mode under automated test —
worth building, since the manual repro depends on Wave Link's startup timing.

**Manual (repro machine):**

1. The exact incident sequence: quit Wave Link, start Tome, launch Wave Link,
   hit Call Capture ~10s later. Expect responsive UI + a clear error, no hang.
2. Same, but with the call audio source set to `Elgato Wave Link Transcriber`
   (two binds against the initializing driver).
3. Unplug the Wave XLR dock mid-session — the existing watchdog rebuild path
   must still recover.
4. AirPods connect mid-session (the 2026-07-06 regression suite).
5. Launch Tome while Wave Link is mid-initialization (AC-3).

## Interim mitigation (until this ships)

Don't start a recording within ~15s of launching Wave Link (or any
virtual-audio host). If Tome does hang, force-quit is safe: the transcript is
flushed per-utterance, and the session WAV is recovered by the launch-time
orphan scan.

## Open questions

1. **Deadline value** — 5s proposed. Too aggressive for a cold USB interface
   enumerating on a busy machine?
2. **Timed-out mic bind: fail the start, or retry once after a short delay?**
   A retry would paper over a driver that is merely slow to initialize (the
   common case here) at the cost of doubling the worst-case wait to ~10s.
3. **Does the wedge latch belong per-device or global?** Global is simpler and
   matches the observed failure (driver-wide), but would fail a bind to a
   healthy built-in mic while an unrelated virtual device is stuck.
4. **Executor granularity** — one serial queue for all HAL work is the safe
   default, but it serializes the two legs' bring-up (~30 ms each, so the cost
   is negligible in the healthy case). Confirm that's acceptable rather than
   one executor per capture instance.

## Out of scope

- Rewriting the capture stack on CoreAudio process taps (catalogued in the
  2026-07-24 spec).
- Any change to `SystemAudioCapture`: its bring-up is already `async`
  (`SCShareableContent` and `startCapture()` are awaited), so the SCK leg does
  not block the main actor and is the natural fallback when the HAL is wedged.
- Watchdog/gate policy changes. Those mechanisms are correct; they were simply
  unreachable while the actor they run on was blocked. This spec restores
  their ability to run, nothing more.

## Appendix — evidence

- `log show --predicate 'subsystem == "com.dloomis.tome"'` for the 19:01:37
  session: `MIC-1` → `MIC-2` → `MIC-3` → `MIC-4` → `MIC-5` → `MIC-7`, then
  nothing. `MIC-8` absent = `AVAudioEngine.start()` never returned.
- `launchd[1]: Successfully spawned WaveLinkMacOS[34238]` at 19:01:23.157.
- Wave Link emitting `AudioConverter.cpp:1327 … in-process GetProperty call
  returned 1886547824` (`pmpx`, four-CC) at thousands/sec across 19:01:28–30.
- No entry for Tome in `~/Library/Logs/DiagnosticReports` or
  `/Library/Logs/DiagnosticReports`; `last-crash.log` 0 bytes with an mtime of
  18:43 (the launch that later hung) — i.e. the signal handler never ran.
- Environment: macOS 26.5.2, Wave Link 3.x (`WaveLink3VirtualAudio.driver`),
  Wave XLR Dock MK.2 + MV7+, Tome 1.6.0 build `1.6.0-2-g411bc82-dirty`.
