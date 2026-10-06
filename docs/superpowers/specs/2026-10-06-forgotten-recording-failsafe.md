# Forgotten-Recording Failsafe — Auto-Stop on Departure

**Date:** 2026-10-06
**Status:** Implemented 2026-10-06 (see *Implementation notes*); manual acceptance owed
**Type:** Feature (session lifecycle / capture UX)
**Prereq reading:** `2026-07-13-stop-recording-confirmation-design.md` (why a
stop is expensive), commit `55f086b` (why silence alone stopped being allowed to
end a session), `2026-07-25-main-thread-capture-bind-hang.md` (HAL rules every
new signal here must obey)

## Problem / Motivation

Recordings get left running after the meeting ends — most often the last
meeting of the day, where the laptop is then undocked and carried home still
recording. Three properties of the current code make that worse than it sounds:

1. **Nothing ends a session across sleep.** The capture watchdog sees the
   post-wake tick gap, logs `system slept; resetting stall windows`, and carries
   on. A session started at 4:30 pm resumes the next morning on whatever mic the
   Mac wakes up with.
2. **The silence prompt can wait forever.** After `silenceAutoStopSeconds` the
   user is asked (ControlBar row + actionable notification). If they have left,
   nobody answers, and recording continues. Meeting-time Focus modes suppress
   the notification anyway.
3. **A live session holds `.idleSystemSleepDisabled` + `.idleDisplaySleepDisabled`**
   (`beginLiveActivity`). A forgotten session at a docked desk therefore keeps
   the Mac awake and the display on — it never idle-locks — all night.

The fix cannot be "stop on silence": that was the behavior until 2026-06-06 and
it ended sessions mid-meeting, because a quiet stretch reads exactly like a
finished call. It also cannot be "stop when the default mic changes": AirPods
dying or a Bluetooth flip changes the default mic in the middle of live calls,
and on a Wave Link machine the default mic is a *virtual* device that does not
change on undock at all.

## Key insight

Two kinds of evidence exist, and each is unreliable alone:

- **Silence** — the judged leg (`SilenceSignal`) has gone quiet. Alone it means
  "maybe done, maybe a pause". Today's answer — ask — is right.
- **Departure** — the physical or session context changed: undocked, mic or
  output route moved, screen locked, Mac slept. Alone it means "maybe left,
  maybe carrying the call to another room".

**Together they are near-certain.** A departure *while or shortly before* the
call goes quiet is what "I walked away and forgot" looks like, and it is not
what any live meeting looks like. So:

> Departure does not stop a recording. It **shortens the silence window** from
> `silenceAutoStopSeconds` (ask) to 20 s, and **changes the outcome** from a
> question to a 30 s countdown that stops unless overridden.

Sleep is the one departure signal strong enough to stand alone: a session that
was suspended for minutes has a hole in it regardless and nobody is still in
that meeting.

## Design

### 1. Rules

| # | Trigger | Outcome |
|---|---------|---------|
| **R1** | Mac slept ≥ 3 min with a session live | Stop at wake. No countdown (the user may be behind the lock screen; there is nothing to keep). Notice explains why. |
| **R2** | A departure signal within the last 5 min **and** 20 s of *trusted* silence | 30 s countdown → stop. Audio resuming cancels it; **Keep Recording** cancels it. |
| **R3** | Silence prompt unanswered for 10 min (i.e. trusted silence ≥ `silenceAutoStopSeconds` + 600) | Same 30 s countdown → stop. Off when the silence prompt is off (`silenceAutoStopSeconds == 0`). |

R3 is the catch-all for leaving *without* any hardware change (docked Mac left
on the desk). It is the only rule that acts on silence alone, and it is not the
June behavior: 12 minutes of continuous far-end silence, a prompt and a
sounding notification both ignored, then a visible countdown.

Nothing here changes how a session *runs* after an undock — mic fallback,
re-adoption, the system-leg rebuild all behave exactly as today. The failsafe
only observes and, at the end, calls the existing `stopSession()`.

### 2. Departure signals (phase 1)

Every signal is an *event* that sets a 5-minute latch. Signals are deliberately
cheap and mostly HAL-free; none of them triggers a HAL call on the main actor.

| Signal | Source | Notes |
|---|---|---|
| `wokeFromSleep` | 1 s session tick sees ≥ 30 s *asleep* since the previous tick: `ContinuousClock` gap minus `SuspendingClock` gap | ≥ 180 s is R1 instead. No dependency on `NSWorkspace.didWakeNotification` ordering. The subtraction matters: a frozen main actor advances both clocks and must not read as a sleep. |
| `displayRemoved` | `NSApplication.didChangeScreenParametersNotification`, `NSScreen.screens.count` dropped | The most reliable undock signal on a routed-audio machine. AppKit only. |
| `audioDeviceRemoved` | existing `kAudioHardwarePropertyDevices` listener → 2 s debounce → `MicCapture.availableInputDevicesResult()` diffed against the previous UID set | Query lane. `.unavailable` is **no evidence**: keep the old snapshot, emit nothing. Catches the physical dock mic disappearing behind Wave Link's persistent virtual devices. |
| `micRouteChanged` | the default-input listener firing (before its `userSelectedDeviceUID.isEmpty` guard — the fire is evidence either way); a *mid-session* raise of `micFallbackMessage` | Listener fire needs no query. The start-time fallback raise is not a signal. Re-adoption (`[MIC-READOPT]`) is an *arrival*, not a departure — never a signal. |
| `outputRouteChanged` | new `kAudioHardwarePropertyDefaultOutputDevice` listener, same shape as `installDefaultDeviceListener` | AirPods coming out at the end of a call. |
| `callSourceLost` | device-mode system leg falling back to SCK mid-session because the device vanished | Existing transition; emit only. |
| `screenLocked` | `DistributedNotificationCenter` `com.apple.screenIsLocked` | Manual lock only in practice — the live-activity assertion prevents idle lock. |

The device-list listener is currently installed only when a call-audio source
is configured; it is now installed for every session. The engine always emits
signals — whether they matter is the policy's call (`enabled`), not the
engine's.

The engine forwards its signals through one callback
(`engine.onDepartureSignal: ((DepartureSignal) -> Void)?`), wired by
`ContentView` in its boot task next to the API callbacks. The AppKit /
distributed-notification observers live in a small `@MainActor`
`DepartureMonitor` (`App/DepartureMonitor.swift`) that is started and stopped
with the session and funnels into the same sink.

### 3. Trusted silence — unavailable ≠ silent ⚠

The countdown may only be armed by silence the app can vouch for. A system leg
that stalled mid-meeting reads as level 0, and after an undock a leg is quite
likely mid-rebuild. So the policy keeps its own counter beside
`silenceSeconds`:

```
trusted = (judgedLegDelivering && silenceSeconds > 0)
            ? min(trusted + 1, silenceSeconds)
            : 0
```

`engine.judgedLegIsDelivering(farEndHeard:)` is true when the leg
`SilenceSignal` is judging produced a **tap-written** buffer within the last
5 s — the system leg (whichever source is bound) once `farEndHeard`, the mic
before that. Seeded timestamps do not count (same discipline as
`CaptureStallDetector.evaluate(canResume:)`: require `firstSampleTime != nil`
for SCK), so a watchdog rebuild that re-seeds every 15 s can never accumulate
20 trusted seconds. A leg delivering digital zeros *is* delivering — quiet is
what we are measuring.

R2 and R3 both read `trusted`, never `silenceSeconds`. R1 reads neither.

### 4. `AutoStopPolicy` — a pure reducer ⚠

`Models/AutoStopPolicy.swift`, same shape as `SessionTypeResolver`: no clocks,
no AppKit, everything injected, fully truth-table tested.

```swift
enum DepartureSignal: Sendable, Equatable {
    case wokeFromSleep, displayRemoved, audioDeviceRemoved, micRouteChanged,
         outputRouteChanged, callSourceLost, screenLocked
}
enum AutoStopReason: Sendable, Equatable {
    case slept(seconds: Int)
    case departure(DepartureSignal)
    case unansweredSilence
}
enum AutoStopAction: Equatable {
    case none, beginCountdown(AutoStopReason), cancelCountdown, stop(AutoStopReason)
}
struct AutoStopPolicy {
    static let longSleepSeconds = 180
    static let sleepGapSeconds = 30
    static let latchSeconds = 300
    static let departureSilenceSeconds = 20
    static let unansweredPromptSeconds = 600
    static let countdownSeconds = 30
    static let settleSeconds = 60

    mutating func step(_ inputs: Inputs) -> AutoStopAction   // once per 1 s tick
    mutating func keepRecording(now: ContinuousClock.Instant)
    mutating func reset()
}
```

`Inputs`: `enabled`, `now`, `tickGapSeconds`, `newSignals`, `silenceSeconds`,
`judgedLegDelivering`, `silencePromptLimit`.

`step` evaluates in this order — the order is the spec:

1. `!enabled` → reset, `.none`.
2. `tickGapSeconds ≥ longSleepSeconds` → `.stop(.slept)`.
3. Countdown active, `now ≥ deadline` and `silenceSeconds > 0` →
   `.stop(reason)`. The deadline is a clock instant, so a countdown
   interrupted by a lid close fires on the first tick after wake. Audio that
   returned on the deadline tick itself (`silenceSeconds == 0`) falls through
   to step 8 and cancels — Decision 1 admits no one-second race. A leg that
   merely stopped delivering gets no such pass, or a wake would withdraw the
   countdown it should complete.
4. `tickGapSeconds ≥ sleepGapSeconds` → append `.wokeFromSleep` to the signals.
5. Update `trusted` (§3).
6. Any signal, unless inside the settle window → latch
   `(reason: first signal, expires: now + latchSeconds)`. A second signal
   extends the expiry but keeps the first reason.
7. Latch expired → clear.
8. Countdown active and `trusted == 0` → `.cancelCountdown`. The latch stays.
9. No countdown: latch set and `trusted ≥ departureSilenceSeconds` →
   `.beginCountdown(.departure(signal))`; else `silencePromptLimit > 0` and
   `trusted ≥ silencePromptLimit + unansweredPromptSeconds` →
   `.beginCountdown(.unansweredSilence)`.

`keepRecording` clears the countdown and the latch and opens a 60 s settle
window — an undock produces a burst of signals over several seconds, and a
"keep" must not be answered by a second countdown from the tail of the same
burst. R1 ignores the settle window. A later, separate departure latches
normally, so carrying the laptop to a conference room and saying "keep" still
leaves the end of *that* meeting protected.

### 5. `ContentView` wiring ⚠

- `@State private var autoStop = AutoStopPolicy()` — the policy owns the
  countdown (`autoStop.countdown: (reason, deadline)?`), so there is one source
  of truth. Reset at the same three sites that reset `silenceSeconds` /
  `silencePromptActive` / `farEndHeard`.
- The existing 1 s silence task calls `autoStop.step(...)` after it updates
  `silenceSeconds`, draining the signals queued since the last tick. The
  previous tick's `ContinuousClock.now` is kept beside the loop to compute the
  gap.
- `.beginCountdown` → set `autoStopCountdown`, show the panel (§6), post the
  countdown notification, withdraw the silence prompt's notification. The
  ControlBar shows the countdown row *instead of* the silence prompt — one
  question at a time.
- `.cancelCountdown` → tear the surfaces down; the silence prompt resumes
  under its own rules.
- `.stop(reason)` → `autoStopSession(reason:)`: log
  `[AUTOSTOP] reason=… trustedSilence=…s slept=…s`, post the "stopped" notice,
  then call **`stopSession()` unchanged**. Its re-entrance guard covers every
  race (API stop, notification stop, the Stop dialog).
- **Keep Recording** (panel, ControlBar row, notification action) →
  `autoStop.keepRecording(now:)` + the existing `dismissSilencePrompt()`
  (which zeroes `silenceSeconds`, re-arming everything from a full window).
- **Stop Now** → `stopSession()` directly; like the silence prompt's
  "Stop & Save" it is already a confirmation and skips `StopConfirmationModel`.
- The defensive `guard isRunning else { … }` branch of the tick also clears
  the countdown, as it does the silence prompt.
- `willSleepNotification` gets one job only: `transcriptLogger.flushIfNeeded()`
  and a `[AUTOSTOP] will sleep` log line. It never stops anything — the sleep
  duration is unknowable at that point, and a brief accidental lid close
  should not end a meeting.

R1's stop runs while the capture graph is settling after wake. That is the same
`engine.stop()` every other stop uses (HAL teardown on the `.bind` lane with
its 5 s deadline); no new teardown path is introduced, but the AC run must
exercise it against a wake with a changed device set.

### 6. Countdown surfaces

The countdown has to be seen by someone who is not looking at Tome, without
being answerable by accident.

- **Floating panel** (`Views/AutoStopPanel.swift`) — a non-activating `NSPanel`
  (`.nonactivatingPanel`, `becomesKeyOnlyIfNeeded`, `hidesOnDeactivate = false`,
  level `.floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`) hosting a
  small SwiftUI view: reason line, a large `0:30` countdown, **Keep Recording**
  (prominent) and **Stop Now**. It never takes key focus, so a Return or Space
  typed into the meeting app cannot answer it — the reason this is not an
  `NSAlert`, which would also block the main actor the engine lives on. One
  alert sound at presentation. Its `sharingType` follows the stealth toggle
  like every other Tome window.
- **ControlBar row** — the `silenceStopPrompt` layout with a countdown label:
  "Undocked and the call is silent — stopping in 0:24".
- **Notification** — new category `TOME_AUTOSTOP_COUNTDOWN` with **Keep
  Recording** / **Stop Now** actions, fixed request id, withdrawn on cancel.
  Best-effort only; Focus modes will usually eat it.
- **After the stop** — a plain notification, "Tome stopped recording", with the
  reason in words ("Your Mac was asleep for 14 hours", "The display was
  disconnected and the call had been silent for 50 seconds", "No call audio
  for 12 minutes and the stop prompt went unanswered"), plus the same text in
  the existing banner slot. The normal completion notification still follows.

Reason copy comes from one `AutoStopReason.userDescription` so the panel, row,
notifications and log agree.

### 7. Settings

- `AppSettings.autoStopWhenAway: Bool`, default **on**, UserDefaults key
  `autoStopWhenAway`. Off → `enabled: false` → the policy is inert and nothing
  about today's behavior changes.
- Settings ▸ (the tab holding **Silence**) gains the toggle "Stop automatically
  when I've left" under the slider. The slider's caption currently promises
  "Recording never stops without your confirmation" — rewrite it: confirmation
  is still the rule for silence, with the three exceptions above stated
  plainly.
- The seven constants stay constants (candidates for the REST tunables later).

### 8. Phase 2 — "the call app hung up" (shadow mode first)

The best end-of-meeting signal is not hardware at all: a process that had been
running audio **input** for a minute or more stops doing so
(`kAudioProcessPropertyIsRunningInput`, already read by
`AudioProcessInspector`). That is a hang-up, in any conferencing app or browser,
with no bundle-ID table — excluding Tome itself and
`mixPublishingMixerBundleIDs`. As a departure signal it would turn "forgot to
stop, stayed at the desk" from a 12-minute R3 into a ~50-second R2.

It ships **log-only** first (`[AUTOSTOP-SHADOW] input released by <bundle>`),
polled every 5 s on the HAL `.query` lane (an unanswered poll is no evidence).
The unknown is whether any app releases input on *mute* rather than on hang-up;
a week of shadow logs against real meetings answers that. Promote to a real
`DepartureSignal` only if it does not.

### 9. API

No change. An auto-stop is a `stopSession()`; the state machine runs
`recording → transcribing → complete` as for any stop and WhisperCal's link
path sees `complete` as usual. (Follow-up, not in scope: a `stopReason` status
field beside `resolution`.)

## Edge cases

- **Clamshell undock** (lid closed, external display): pulling the cable sleeps
  the Mac at once. Signals may or may not land before sleep; it does not
  matter — R1 (or, for a short sleep, the `wokeFromSleep` latch) decides at
  wake.
- **Carrying a live call to another room:** signals latch, the far end is
  audible, `trusted` stays 0, the latch expires after 5 min. Nothing shown.
- **Quiet stretch right after a Bluetooth flip mid-meeting:** the false-positive
  shape. Requires 50 s of unbroken far-end silence *and* an ignored floating
  panel with a sound. Any far-end audio during the countdown cancels it.
- **System leg stalled or rebuilding:** `trusted` is 0; neither R2 nor R3 can
  arm. A leg that never recovers means the failsafe never fires on silence —
  the safe direction. R1 still works.
- **Short sleep (30 s – 3 min):** audio has a hole but the session continues;
  if the call does not come back, R2 ends it ~50 s after wake.
- **Voice memo / in-person session:** `farEndHeard` is false, so the mic is the
  judged leg; conversation in the room keeps `trusted` at 0.
- **Stop dialog or silence prompt already up:** countdown takes the ControlBar
  slot; the modal Stop dialog stays on top and either answer works. Session
  end by any path clears all three.
- **Short-session discard / `.auto` resolution:** untouched — an auto-stopped
  session is resolved, discarded or kept by exactly the rules a manual stop
  gets.
- **Docking mid-session** (pinned mic re-adopted): not a departure signal.

## Non-goals

- Trimming the silent tail off an auto-stopped transcript. (Worth a follow-up
  for R3, where up to 12 minutes of post-call mic-side lines can be in the
  note.)
- Resuming an auto-stopped session. A stop stays final.
- Calendar- or scheduled-end-based stopping (couples core behavior to an
  external tool; meetings overrun). A scheduled end could later become one
  more *signal*, never a rule.
- A hard maximum session length.
- Any change to capture behavior after an undock.

## Alternatives considered

| Option | Why not |
|---|---|
| Stop on default-mic change, 10 s modal (the original suggestion) | The default mic does not change on undock when it is a mixer's virtual device; it *does* change mid-call on every AirPods/Bluetooth flip; a clamshell undock sleeps before any countdown can show, which is the overnight case; a key-window modal can be answered by a stray keystroke. Kept as one signal of several, gated on silence. |
| Stop on silence alone | The pre-June behavior; ended sessions mid-meeting. |
| Stop at `willSleep` | Duration unknown; a 10-second accidental lid close would end a meeting. |
| Ask at wake instead of stopping | The user is behind the lock screen for the first seconds; the meeting is over either way. |

## Tests (`Tome/Tests/TomeTests/`)

`AutoStopPolicyTests` — the truth table, written before the reducer:

1. Disabled → never anything, for every input combination below.
2. Gap ≥ 180 s → `.stop(.slept)` regardless of silence, latch, settle window.
3. Gap 30–179 s → latches `.wokeFromSleep`; no stop without trusted silence.
4. Signal + 20 trusted s → `.beginCountdown`; 19 s → `.none`.
5. Signal while already silent ≥ 20 s → countdown on that tick.
6. Signal, then silence beginning 4 min later → countdown; 6 min later → none.
7. Silence with `judgedLegDelivering == false` never accumulates; alternating
   5-of-15 s delivery (the rebuild re-seed pattern) never reaches 20.
8. Countdown + audio resumes → `.cancelCountdown`, latch retained, re-arms
   after a fresh 20 s.
9. Countdown runs to deadline → `.stop` exactly once.
10. Countdown + sleep gap (short and long) → `.stop` on the first tick.
11. `keepRecording` → no countdown for 60 s despite new signals; a signal at
    61 s latches.
12. R3: `trusted == limit + 600` → countdown; `limit == 0` → never; a
    `silenceSeconds` reset (Keep on the silence prompt) restarts the count.
13. Second signal extends the latch but the reason stays the first.

Plus: `judgedLegIsDelivering` (seeded timestamp does not count; device mode vs
SCK), the device-list diff (`.unavailable` keeps the snapshot and emits
nothing; add-only change emits nothing), `AutoStopReason.userDescription`.

## Manual acceptance (reference machine, Wave Link routing)

1. Call, hang up, pull the dock cable with the lid open → panel within ~25 s,
   stop at 30 s, note saved, notice names the display/device.
2. Same, click **Keep Recording** → recording continues; no second panel from
   the same undock.
3. Clamshell: hang up, pull the cable, wait 5 min, open → session already
   stopped at wake, notice says how long it slept. Check `[AUTOSTOP]` in
   `/usr/bin/log show`.
4. Live call, pull the cable, keep talking on the built-in mic → no panel.
5. Live call, close the lid for 20 s, reopen, rejoin → session survives.
6. Docked, hang up, walk away untouched → silence prompt at 2 min, countdown at
   12 min, stopped; display sleeps afterwards.
7. Voice memo with AirPods, remove them mid-sentence, keep talking → no panel.
8. Stealth mode on, share screen, trigger a countdown → panel absent from the
   share.
9. Record which signals actually fired on undock (`[AUTOSTOP] signal=`) — this
   decides whether `audioDeviceRemoved` needs output devices too.

## Decisions (2026-10-06)

1. **An active meeting is never terminated.** "Active" means audible *system*
   audio — not sound picked up by the mic. R2 and R3 cannot arm while the far
   end is audible (`trusted` is 0), and once the far end has been heard the mic
   alone never holds a session open (`SilenceSignal`, unchanged). R3 is
   accepted on those terms: it only ever acts on 12 minutes without call audio.
   A session ends without the user only on clear end-of-meeting evidence — a
   long sleep, or departure plus trusted call silence. The one place mic audio
   still counts is a session whose far end was *never* heard (voice memos,
   in-person meetings), where the mic is the meeting.
2. **Countdown: 30 s.**
3. **Default on**, one Settings toggle.

## Open risks

1. Whether `didChangeScreenParameters` fires before the forced clamshell sleep
   is unknown and does not need to be known (R1 covers it); AC 9 will show.
2. Behavior during dark wakes (Power Nap) is assumed to be "the tick loop does
   not run"; if AC 3 shows otherwise, R1 must key on the summed gap.
3. `callSourceLost` can fire on an *unanswered* lookup: `bringUpSystemLeg`
   resolves through `deviceID(forUID:)`, which cannot tell absent from
   refused. The SCK fallback is real either way and the signal only latches,
   so this stays inside the trusted-silence gate; fixing it means moving
   `resolveSystemSource` onto `deviceIDResult(forUID:)`, out of scope here.
4. A Wave Link republish that outlasts the 2 s debounce reads as
   `audioDeviceRemoved` mid-meeting — the "quiet stretch after a Bluetooth
   flip" edge case, by a second route.
5. `audioDeviceRemoved` is blind to a removal that lands before the
   session-start snapshot is seeded, and to the first change after a refused
   seed (it can only seed). `displayRemoved` and R1 cover the undock anyway.

## Implementation notes (2026-10-06)

- The engine always emits; `ContentView` drops signals outside a live session
  and the policy ignores them when the setting is off.
- The device-list listener is now installed for every session. Side effect: a
  mic pinned *mid-session* in a session that started on System Default is now
  re-adopted if it drops and returns (previously no listener existed there).
- §8 shipped log-only as specified (`[AUTOSTOP-SHADOW]`); it emits no signal.
- **Sleep is measured on two clocks** (`AutoStopPolicy.TickStamp`), not the
  raw continuous gap the first draft specified — a three-minute main-actor
  freeze would otherwise have been an R1 stop with no countdown.
- **The policy is fed `silenceSeconds` only when it grew since the last tick,
  else 0.** The 100 ms poll zeroes the counter on any audible blip but the 1 s
  tick re-increments it, so a half-second "hello?" between ticks would
  otherwise leave it at 1 and fail to cancel a countdown.
- **Tick order:** silence counter → failsafe step → silence prompt; the prompt
  is not presented while a countdown is up. A leftover silence-prompt
  notification's Keep answers the countdown (settle window included).
- **No in-app post-stop banner.** The `discardNotice` slot is an 8-second
  trash-icon notice that the save banner replaces; the "Tome stopped
  recording" notification is the only post-stop surface.
- The failsafe gates on `isRunning && activeSessionType != nil`, so the
  engine's own teardown after `stopSession()` can't feed it signals.
- Known gaps: the panel does not follow a stealth toggle made mid-countdown;
  like the silence prompt, the tick lives in `ContentView`'s `.task`.
- Tests: 501 passing (`AutoStopPolicyTests`, `AutoStopSurfaceTests`,
  `DepartureSignalEngineTests`, `InputReleaseTrackerTests` are new). Manual
  acceptance on the reference machine is still owed.

## Implementation note — model / effort assignments

Opus implements, Fable orchestrates. Baseline **Opus medium**; three spots are
**Opus high** — tests first, each in its own pass.

| Work | Model / effort | Why |
|---|---|---|
| **§4 `AutoStopPolicy` + truth-table tests** | **Opus high** | The evaluation order *is* the feature, and this is the second attempt at auto-stop — the first one ended live meetings. Tests 1–13 green before any wiring. |
| **§3 `judgedLegIsDelivering` + §2 `audioDeviceRemoved` diff** | **Opus high** | Both restate invariants the codebase has paid for: seeded timestamps are not deliveries, and an unanswered HAL query is not an absent device. No HAL call may land on the main actor. |
| **§5 `ContentView` tick integration, wake-time stop, reset sites** | **Opus high** | Three prompts now share one tick and one ControlBar slot; the stop must stay a plain `stopSession()`; R1 runs while the graph is settling after wake. |
| §2 remaining signal emit sites, `DepartureMonitor`, §6 panel / row / notifications, §7 settings + copy, §8 shadow logger, CLAUDE.md + README | **Opus medium** | Emit-only or presentational, fully specified. |

**Explicitly not changed:** `stopSession()`, `engine.stop()`, `restartMic`,
the re-adoption and rebuild paths, `SilenceSignal`, `StopConfirmationModel`,
`API/**`, `PostProcessingJob`.
