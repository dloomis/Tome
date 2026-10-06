# "Record this meeting?" — Prompt When a Call Is Live and Tome Is Idle

**Date:** 2026-10-06
**Status:** Implemented 2026-10-06; manual acceptance owed
**Type:** Feature (capture UX / meeting detection)
**Prereq reading:** `MeetingDetector.swift` (window-title detection, the chip),
`2026-10-06-forgotten-recording-failsafe.md` §6 + §8 (the floating panel, and
the CoreAudio process-list probe), `2026-07-25-main-thread-capture-bind-hang.md`
(HAL rules every new query here must obey), `2026-09-26-single-record-button-auto-mode.md`
(what a `.auto` start does)

## Problem / Motivation

The failure this fixes is the mirror image of the forgotten-recording failsafe:
**a meeting that never got recorded.** The user joins a Teams call, Tome is
idle in the menu bar, and nobody presses Record — usually because the call
started from a chat ("can you hop on?") rather than a calendar event, so
WhisperCal never fired a `/start`, and the Tome window is behind Teams where
its "Meeting: …" chip can't be seen.

Tome already *knows* the meeting is happening. `MeetingDetector.scan` polls
window titles every 3 s while idle and names the meeting in a chip in the main
window. That chip is pre-start naming only; it never reaches a user who isn't
looking at Tome.

## Key insight

Two signals Tome already reads, each insufficient alone, are near-certain
together:

- **A meeting-titled Teams window** (`MeetingDetector`, via `SCShareableContent`).
  Alone it also matches the pre-join lobby, a popped-out meeting chat, and the
  post-meeting recap window.
- **Teams is running audio *output*** (`kAudioProcessPropertyIsRunningOutput`
  on Teams' CoreAudio process object). Alone it also matches notification
  chimes and ringtones.

A meeting-titled window **and** sustained far-end audio output is what a joined
call looks like, and nothing else looks like it. Output — not input — is the
audio half on purpose: joining muted is the common case, and whether Teams
releases the *input* device on mute is exactly the unknown the failsafe's
`[AUTOSTOP-SHADOW]` probe is still collecting data on. A live call always has
far-end output. The pre-join lobby runs the mic preview (input) but no output
unless the user clicks "test speaker".

> When both signals hold for 10 s, Tome is idle, and this meeting hasn't been
> asked about yet: **ask** — a floating panel over the meeting app plus an
> actionable notification. Accepting is exactly a press of the Record button.
> Nothing ever starts a recording by itself.

## Design

### 1. In-call evidence

`InCallEvidence` for one poll is true iff:

1. `MeetingDetector.scan` returned a `DetectedMeeting` whose `bundleID` maps to
   a `ConferencingApp` with `promptsToRecord == true` (§7 — Teams only in v1);
2. the CoreAudio process list, read on the HAL `.query` lane, contains a
   process running output whose bundle ID **matches** that app — exact, or
   `hasPrefix(appBundleID + ".")`. Field data (14 days of
   `[SYS-CAPTURE] mic-passthrough` lines on the reference machine): Teams
   reports as `com.microsoft.teams2` in 8 sessions and
   `com.microsoft.teams2.modulehost` in 2, never anything else.

Three-valued, not boolean: `.present`, `.absent`, `.unknown`. **Unknown ≠
absent.** An unanswered HAL query (`HALQueryResult.unavailable`) or a failed
process-list read (`nil` from the inspector) is `.unknown`: it neither advances
nor resets the sustain counter. Same discipline as the shadow probe, for the
same reason — a lookup the HAL never answered is not evidence either way.

New in `AudioProcessInspector`: `outputRunningBundleIDs() -> Set<String>?`, a
line-for-line mirror of `inputRunningBundleIDs()` on the output selector,
with the same nil-on-failed-read contract. Blocking HAL reads — `.query` lane
only, never the main actor.

### 2. `MeetingJoinPolicy` — a pure reducer ⚠

`Models/MeetingJoinPolicy.swift`. No clocks, no HAL, no AppKit inside; the
caller steps it once per poll with an `Observation` and acts on the returned
`Action`. Modeled on `AutoStopPolicy`.

```swift
struct MeetingJoinPolicy: Sendable {
    struct Observation: Sendable {
        var meeting: DetectedMeeting?        // nil when none / scan skipped
        var callAudio: Evidence              // .present / .absent / .unknown (§1 half 2)
        var isRecording: Bool                // isLiveRecordingSession || services.isSessionPending
        var now: ContinuousClock.Instant
    }
    enum Action: Equatable, Sendable { case none, prompt(DetectedMeeting), withdraw }

    static let sustainSeconds: Duration = .seconds(10)
    static let instanceGapSeconds: Duration = .seconds(60)
    static let postStopSuppressSeconds: Duration = .seconds(30)
    static let unansweredTimeout: Duration = .seconds(60)

    mutating func step(_ o: Observation) -> Action
    mutating func userAccepted()   // Record pressed on either surface
    mutating func userDeclined()   // Not This Meeting / ✕ / panel timed out
}
```

**State.** One `Instance?` — the current meeting, keyed by **bundle ID only**
(one Teams call at a time; a title change mid-call just updates the display
name and must not re-prompt), with `firstEvidence`, `lastEvidence`, and
`phase ∈ {accumulating, prompted, handled}` — plus `suppressNewInstancesUntil`
and `wasRecording`.

**`step` evaluation order (this order is the spec; pinned by tests):**

1. **Recording.** If `o.isRecording`: set `wasRecording`; if an instance
   exists, mark it `handled` and refresh `lastEvidence` (a recording keeps
   its meeting's instance alive, so a 1-hour recording of a 1-hour call does
   not end in a fresh instance). Return `.withdraw` if it was `prompted`, else
   `.none`. **Nothing below runs while recording.**
2. **Stop edge.** If `wasRecording && !o.isRecording`: clear `wasRecording`,
   set `suppressNewInstancesUntil = now + 30 s`. Why: the user who stops a
   recording *mid-call* (a sensitive stretch, a wrong-meeting start) must not
   be asked "Record this meeting?" ten seconds later. An instance created
   inside the window is born `handled`.
3. **Expiry — before the evidence is read.** If an instance exists and
   `now - lastEvidence ≥ 60 s`: drop it (remember whether it was `prompted`).
   This runs on *every* non-recording poll, not only absent ones: after a
   sleep, a present poll is a **new** call that must sustain its own 10 s and
   must not inherit yesterday's `handled`; and sixty seconds of unanswered
   queries end an instance as intended. (A `prompted` instance whose evidence
   lapses keeps its prompt up to 60 s — the panel's own timeout (§3) usually
   closes it first. Deliberately *not* "withdraw on first missed poll": a Teams
   retitle during screen-share would kill the prompt with no second chance.)
4. **Evidence.** `present` = `o.meeting != nil && o.callAudio == .present`.
   On no meeting, `.absent`, or `.unknown`: return `.withdraw` if step 3
   dropped a prompted instance, else `.none`. No other state change — `unknown`
   neither advances nor resets; `absent` only ages the instance toward step 3.
5. **Present.**
   - No instance, or the instance's bundle ID differs (switched apps): create
     one — `phase = handled` if `now < suppressNewInstancesUntil`, else
     `accumulating`. Return `.withdraw` if the replaced (or step-3-dropped)
     instance was `prompted`, else `.none`.
   - Same instance: `lastEvidence = now`, `meeting = o.meeting` (latest
     title); if `accumulating` and `now - firstEvidence ≥ 10 s` → `prompted`,
     return `.prompt(meeting)`. Otherwise `.none`.

The evidence type is `CallAudioEvidence`; the matcher is
`MeetingJoinPolicy.callAudioEvidence(for:from:)`. A read-only `phase` and
`isPromptAlive` (true iff `prompted`) are exposed for the stale-notification
guard and logging.

`userAccepted` / `userDeclined` set `phase = handled`. There is no snooze: the
instance ends when the call ends, and the next call is a new question.

### 3. Surfaces

Both appear and withdraw together, driven only by `Action`s and the panel
timeout. **Silent** — no `NSSound.beep()`, `content.sound = nil`: this fires
*during* a meeting, into a live mic. (The auto-stop panel beeps into silence;
this one would beep into someone's sentence.)

- **Floating panel** — `MeetingJoinPanelController`, the same non-activating
  `NSPanel` shape as `AutoStopPanelController`: floats over every Space and
  full-screen apps, `canBecomeKey == false`, never activates Tome, first-mouse
  buttons, follows `hideFromScreenShare` via `sharingType`. ⚠ The last one
  matters more here than for auto-stop: a "Record this meeting?" panel caught
  in a shared screen is visible to the people being recorded. Copy:
  "Record this meeting?" / "*Weekly sync* in Teams is live and Tome isn't
  recording." / **Record** · **Not This Meeting**. Auto-hides **60 s** after
  show — **the panel only**: the policy stays `prompted` and the notification
  stays posted, so Record from Notification Center still works for someone
  who stepped away; the instance's own expiry (call ended) or a recording
  start withdraws it.
  Factor the NSPanel setup (`AutoStopPanel` subclass, `FirstMouseHostingView`,
  `position(_:)`) into a shared `FloatingPromptPanel.swift` used by both
  controllers. `AutoStopPanelController` behavior must not change
  (`AutoStopSurfaceTests` stay green).
- **Notification** — new category `TOME_MEETING_JOIN_PROMPT`, actions
  **Record** / **Not This Meeting**, fixed request id
  `tome-meeting-join-prompt` (re-post replaces, withdraw by id). Registered in
  `NotificationPresenter.init`'s single `setNotificationCategories` call.
  Callbacks `meetingJoinRecordAction` / `meetingJoinDeclineAction`, wired by
  `ContentView`'s boot task like the silence actions. **Record from a stale
  notification must not record nothing:** the action closure asks the policy
  whether its instance is still alive (`prompted`); if not — the call has
  ended — it only `NSApp.activate()`s.
- **In-app** — nothing new. The existing chip + Record button are the in-app
  answer; a press there is handled by step 1 (recording → `handled`).

### 4. `ContentView` wiring ⚠

Extend the existing idle meeting-detection `.task` (3 s loop) rather than add
a second poller:

```
every 3 s:
  if isLiveRecordingSession || services.isSessionPending:
      act(policy.step(.init(meeting: nil, callAudio: .absent, isRecording: true, now)))
  else:
      let m = await MeetingDetector.scan(frontmostBundleID:)   // existing; still feeds the chip
      detectedMeeting = m                                         // existing
      var audio: Evidence = .absent
      if let m, conferencingApps[m.bundleID]?.promptsToRecord == true {
          let r = await HALQueue.query(label: "output-running-processes") {
              AudioProcessInspector.outputRunningBundleIDs()
          }
          audio = evidence(for: m.bundleID, from: r)            // pure, §1
      }
      act(policy.step(.init(meeting: m, callAudio: audio, isRecording: false, now)))
```

`act`:
- `.prompt(m)` — if `!settings.promptToRecordDetectedMeetings` or
  `!services.modelProvisioner.canStartRecording`: `policy.userDeclined()` and
  return (no surface; the instance is settled so the toggle flipping later
  doesn't prompt for a meeting half an hour in). Else show the panel, post the
  notification, `diagLog("[JOIN-PROMPT] prompted — \(m.appName)")`.
- `.withdraw` — hide panel, clear notification, log.
- **Record** (either surface) — `policy.userAccepted()`, withdraw both, then
  `startSession(mode: .auto, detectedMeeting: suggestedMeeting)` — byte-for-
  byte the Record button's call. `suggestedMeeting`, not `m`: it already
  honors `useDetectedMeetingNames` and the chip's ✕. `.auto` so the stop-time
  resolver still decides the type (rule 2 fires on `hadMeetingEvidence`;
  rule 3 usually too, since the non-activating panel leaves Teams frontmost).
- **Not This Meeting / ✕** — `policy.userDeclined()`, withdraw both.
- **Panel timeout** — hide the panel, log; no policy call, notification kept.

Reset sites: `stopSession()` and the API-stop path need no policy call — step
2 sees the edge on the next tick. On app termination nothing is persisted.

### 5. Settings

`AppSettings.promptToRecordDetectedMeetings: Bool`, default **on**, key
`promptToRecordDetectedMeetings`. Settings ▸ Output: move the existing
"Auto-name from detected meetings" toggle out of *Filename Template* into a
new **Meeting Detection** section and add below it:

> **Ask to record when a call is live** — When a Teams meeting is running and
> Tome isn't recording, show a prompt over the meeting with a Record button.
> Needs the Screen Recording permission Tome uses to see window titles; the
> prompt never starts a recording on its own.

### 6. Logging

`[JOIN-PROMPT] prompted — Teams` / `withdrawn (<reason>)` / `accepted` /
`declined (<button|disabled>)` / `panel timed out — notification remains`. App name only — the meeting title is a
subject line, and `[DETECT]` already keeps titles out of the log store.

### 7. Table-driven scope

`ConferencingApp` gains `promptsToRecord: Bool`. v1: `true` for both Teams
entries, `false` for everything else. Enabling another family is a one-field
change **after** its in-call audio signature is checked on a real call:

- Zoom / FaceTime / Webex / Slack — native apps; the same output test should
  hold, but `MeetingDetector` yields no *name* for Zoom (`extractZoom` is
  nil), so §1's "returned a `DetectedMeeting`" gate would need a nameless
  variant first.
- Google Meet — browser-hosted; Chrome is running output whenever a YouTube
  tab is open, so the title half carries all the weight there. Likely fine
  (the Meet extractor is strict), unverified.

## Edge cases

- **Pre-join lobby** (meeting-titled window, mic preview, no output) — no
  prompt. If the user clicks "test speaker" for 10 s+, one false prompt;
  declining settles the instance.
- **Notification chime / ringtone** — output for a second or two; the 10 s
  sustain filters it. A ring that goes 10 s+ with a meeting-titled window
  open could prompt — that window is usually the incoming-call sheet, whose
  title is unverified (see *Open risks*).
- **Joined muted** — output still runs; prompt fires. (This is why not input.)
- **WhisperCal `/start` at join time** — `isSessionPending` / recording on the
  next tick → `handled` + `withdraw`. The 10 s sustain gives the calendar path
  a head start, so the common case never shows a prompt at all.
- **User presses Record in Tome before 10 s** — step 1, no prompt ever shown.
- **User stops mid-call** — step 2's 30 s suppression; the re-created
  instance is born `handled`. Stopping *after* the call ended: output is gone,
  no evidence, nothing to suppress.
- **Back-to-back calls** — call A ends (evidence absent ≥ 60 s → instance
  dropped), call B starts → new instance → new prompt. Two calls <60 s apart
  share an instance and the second is not asked about. Acceptable.
- **Teams retitles the window** (screen-share, "Meeting with …" → subject) —
  same bundle ID, same instance; display name updates on the next prompt
  only, which there won't be. No double prompt.
- **No Screen Recording permission** (device/"lean-in" mode never needed it) —
  `MeetingDetector.scan` returns nil, no prompt, and the Settings copy says
  why. Passive polling must never trigger the TCC prompt (existing rule).
- **Model not provisioned** — `.prompt` is dropped via `userDeclined`; the
  user can't record anyway.
- **Sleep / wake** — `ContinuousClock` keeps counting; an instance left over
  from yesterday expires on the first tick (gap ≥ 60 s).
- **Two Teams meeting windows** — `scan` already ranks and returns one.
- **Tome window visible** — panel still shows (it's cheap and the user may be
  looking at Teams on another display). The chip is unchanged.

## Non-goals

- Starting a recording automatically. Ever. (Same reason the failsafe never
  stops one silently — and here a false positive records a call the user
  chose not to record.)
- Detecting calls in apps without a window-title signature, or any
  Accessibility-API scraping of Teams' UI for mute/participant state.
- A snooze or "never for this meeting title" memory. The instance model
  already bounds prompts to one per call.
- Rebuilding the in-call signal on `AudioProcessInspector` alone when the
  title scan is unavailable.

## Alternatives considered

- **Window title alone** (just promote the chip to a prompt) — fires in the
  lobby and on the recap window; the user would learn to dismiss it. Rejected.
- **Input running** instead of output — fails for muted joins if Teams
  releases input on mute, which is unmeasured; output has no such failure.
- **`isRunningInput && isRunningOutput`** (the mic-passthrough signature) —
  strictly stronger when both hold, but inherits the mute unknown. Can be
  reconsidered once the shadow probe has a week of data; the evidence
  function is one pure switch.
- **Launch-time / `didActivateApplication` triggers** instead of polling —
  the scan loop already runs every 3 s while idle; adding event sources only
  adds paths to test.
- **Re-prompt on a timer** while the call stays unrecorded — nagging into a
  live meeting is worse than one missed prompt.

## Tests (`Tome/Tests/TomeTests/`)

`MeetingJoinPolicyTests` — one test per numbered case, each a truth-table row:

1. Present ×3 polls (9 s) → `.none`; 4th poll (12 s) → `.prompt`.
2. Present, present, **unknown**, present — `unknown` neither resets nor
   advances; prompt lands when 10 s of *answered* presence spans.
3. Present, absent, present — the absent poll does not reset (`lastEvidence`
   ages but `firstEvidence` holds); prompt at 10 s from the first.
   *(Decision: sustain is wall-clock from first evidence, not consecutive
   polls — chimes are filtered by needing the window too.)*
4. Prompted, then `isRecording` → `.withdraw`, phase `handled`; subsequent
   presence → `.none` forever for this instance.
5. Prompted, `userDeclined()`, presence continues → `.none`.
6. Recording → stop → presence within 30 s → instance born `handled`, no
   prompt; presence 31 s+ after stop → prompts normally.
7. Instance alive, absent for 59 s → kept; 60 s → dropped and `.withdraw` if
   it was prompted; new presence → new instance → prompts after 10 s.
8. Recording for 3600 s with no observations of the meeting keeps the
   instance alive (step 1 refreshes `lastEvidence`).
9. Bundle-ID change mid-instance (Teams → Zoom entry, hypothetically) →
   replaces the instance, `.withdraw` if prompted.
10. Title change with the same bundle ID → same instance, no second prompt.
11. `prompted` + `userAccepted()` → `handled`; a later `.withdraw` is never
    emitted twice.
12. Stale-notification guard: `isPromptAlive` (or equivalent) is false after
    the instance expires.

`CallAudioEvidenceMatchTests` — the pure `callAudioEvidence(for:from:)`:
`com.microsoft.teams2` exact; `com.microsoft.teams2.modulehost` prefix;
`com.microsoft.teams2helper` (no dot) does **not** match; `.unavailable` →
`.unknown`; `.answered(nil)` → `.unknown`; `.answered([])` → `.absent`.

`ConferencingAppTableTests` — exactly the two Teams entries have
`promptsToRecord == true`.

`NotificationCategoryTests` (extend whatever covers the existing two
categories, or add) — the join category is registered with both actions.

## Manual acceptance (reference machine, Wave Link routing)

1. Tome idle, join a Teams meeting **muted** from a chat link. Panel +
   notification within ~15 s, naming the meeting. **Record** → session starts,
   provisional note named after the meeting, panel and notification gone.
   Stop → resolves `callCapture`.
2. Open a meeting's pre-join screen, wait 30 s, don't join → no prompt.
3. Receive a Teams chat message with the sound on → no prompt.
4. Recording a call, press Stop mid-call → no prompt for the rest of that
   call.
5. Join a calendar meeting WhisperCal starts → no prompt (or one that
   withdraws within 3 s of the API start).
6. Turn on "Hide from screen share", get prompted, share the screen → panel
   absent from the shared feed.
7. Settings toggle off → join a call → no prompt; `[JOIN-PROMPT] declined
   (disabled)` logged once.
8. Grep `[SYS-CAPTURE] mic-passthrough` after step 1 to confirm the Teams
   bundle ID the process list reported; add any new variant to the test.

## Open risks

- **Incoming-call sheet title.** If Teams titles the ringing window with the
  caller's name and no nav label, a 10 s+ ring prompts before the call is
  answered. Declining costs one click; if it recurs, add the observed prefix to
  `extractTeams`'s nav-label filter.
- **Teams output without a call** — Teams playing a recorded meeting or a
  voicemail in a meeting-titled window would look live. Rare; declining
  settles it.
- **`SCShareableContent` cost.** Unchanged — the scan already runs every 3 s;
  this adds one cheap process-list read per poll, only when a Teams window is
  already found.
- **Panel timeout vs. a user who was away from the keyboard** — after 60 s
  the panel is gone and only the notification remains (still actionable until
  the call ends); if Focus swallowed it,
  the call goes unrecorded. Same bound the auto-stop panel accepts; the
  alternative is a panel that sits over the meeting indefinitely.

## Decisions (2026-10-06)

- Scope: **Teams in v1, table-driven** (`promptsToRecord`), other families
  after a real-call check.
- Surfaces: **panel + notification**, both silent.
- Audio half of the evidence is **output**, not input.
- Accepting is a `.auto` start with `suggestedMeeting` — the Record button's
  exact call.
- Default **on**.

## Implementation note — model / effort assignments

Opus implements, Fable orchestrates. Baseline **Opus medium**; two spots are
**Opus high** — the policy first, tests before wiring.

| Work | Model / effort | Why |
|---|---|---|
| **§2 `MeetingJoinPolicy` + the 12 truth-table tests, §1 `evidence(for:from:)` + match tests** | **Opus high** | The step order *is* the feature: step 1/2 (recording → handled, post-stop suppression) are what keep this from nagging a user who just chose not to record, and `unknown ≠ absent` is a paid-for invariant. All tests green before any UI exists. |
| **§4 `ContentView` wiring** | **Opus high** | Merges into the one idle loop that also feeds the chip; the recording branch must run every tick (not just idle), the HAL read must stay on the `.query` lane, and Record must be the button's exact call path — no second start path. |
| §1 `outputRunningBundleIDs`, §3 `FloatingPromptPanel` extraction + `MeetingJoinPanelController`, §3 notification category + callbacks, §5 settings + copy, §6 logging, §7 table flag, CLAUDE.md | **Opus medium** | Mirrors of existing code, fully specified. The panel extraction is a refactor with existing tests as the net. |

**Explicitly not changed:** `MeetingDetector.scan` and its extractors,
`startSession` / `stopSession`, `SessionTypeResolver`, `AutoStopPolicy`,
`AutoStopPanelController`'s observable behavior, `API/**`, `TranscriptionEngine`.
