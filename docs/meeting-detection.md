# Meeting Detection

Tome detects the **active meeting** (Microsoft Teams, Google Meet, …) and offers its
name for the Call Capture filename, so a standup recorded from Teams lands as
`2026-06-19 14-30-00 C2Ops Daily Standup Call.md` instead of the generic
`… Call Recording.md`.

Detection is a **suggestion, never mandatory**: the name shows as a dismissible chip
above the Call Capture button, and a single ✕ ignores a false match.

## How it works

Detection reads on-screen **window titles** via `SCShareableContent` — the same
Screen Recording permission Tome already holds for system-audio capture. Enumerating
windows does **not** start an `SCStream`, so it neither lights the recording indicator
nor needs a new permission, and it makes no network calls (consistent with Tome's
on-device posture).

`MeetingDetector.scan(frontmostBundleID:)` (`Sources/Tome/Audio/MeetingDetector.swift`):

1. `guard CGPreflightScreenCaptureAccess()` — passive polling **never** triggers a
   permission prompt. If permission was never granted (the user has never run a call
   capture), detection silently yields nothing and lights up after the first capture.
2. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`.
3. Keep windows owned by a known conferencing app (`conferencingApps` table),
   normal layer, non-empty title, reasonably sized. Only value types (`title`,
   `bundleID`, family) leave the function — `SCWindow` is not `Sendable`.
4. Order candidates: the frontmost app first, then a fixed family priority.
5. Run the per-app title extractor; return the first real meeting name.

`ContentView` polls every 3s while idle (gated on `!isRunning`), reads the frontmost
bundle ID on the MainActor, and stores the result in `detectedMeeting`.

## Per-app title extraction (heuristic)

Window-title formats drift by app version and OS locale, so extractors are pure,
individually tunable string functions. The ✕ dismiss is the backstop for misses.

| App | Title shape | Result |
|-----|-------------|--------|
| **Teams** | `<subject> \| Microsoft Teams` | strip suffix; reject nav labels (`Chat`, `Calendar`, …) → **subject**. Reliable. |
| **Google Meet** (browser) | `Meet - <name>` / `<name> - Google Meet` | strip; reject bare `abc-defg-hij` code and the landing page → **name**. Only the *active* tab is visible; named meetings only. |
| **Zoom** | `Zoom Meeting` (generic) | no topic exposed → **no name** (v1). |
| Webex / FaceTime / Slack | varies | best-effort; **no name** (v1). |

"Detected but unnamed" (the common Zoom case) shows **no chip** — the feature only
surfaces when it has a real name to offer, so there are no noisy false positives.

## Naming flow & precedence

A detected meeting is just a locally-sourced `MeetingContext`. It rides the existing
`meetingContext.subject → TranscriptLogger.updateContext() → TranscriptFinalizer`
rename pipeline (already used for API-driven meetings), which writes the `context:`
frontmatter / `## Context` body and renames the file to `<date> <subject>.md` at stop.
No new filename code.

`ContentView.startSession` resolves the name lowest-priority-last:

```
API suggestedFilename  >  API meetingContext.subject  >  autodetected title  >  filenameCallLabel
```

```swift
let apiNamePresent = meetingContext != nil || suggestedFilename != nil
let effectiveContext = meetingContext               // API caller — authoritative
    ?? (apiNamePresent ? nil                        // API named it (even filename-only) → no autodetect
        : detectedMeeting.map { MeetingContext(subject: $0.title, …) })   // else fall back
```

API-initiated sessions pass their own `meetingContext`/`suggestedFilename` and never
pass `detectedMeeting`, so **API meeting info always overrides autodetection**. The two
name sources are therefore mutually exclusive per `startSession` call; the `apiNamePresent`
guard makes the rule hold defensively even if a future caller passed both — and keeps the
**displayed** title (`effectiveContext.subject`, shown in the Stop subtitle) in lockstep
with the saved filename, so a `suggestedFilename`-only call never shows an autodetected
name the transcript won't actually use. `suggestedFilename` (API only) additionally
outranks all context in the finalizer.

## UX

- **Chip** above the Call Capture button: `Meeting: <name>` with a ✕ to ignore.
  Default-on — Call Capture adopts the name automatically; ✕ falls back to the label.
- Dismissal is keyed to the title: a *different* meeting re-arms the chip; the same one
  stays hidden. Cleared when a session ends.
- During recording the Stop subtitle shows `Call Capture · <name>` so the chosen name
  is visible throughout the session.
- Global off-switch: **Settings ▸ Output ▸ Meeting Detection ▸ "Auto-name from detected
  meetings"** (`AppSettings.useDetectedMeetingNames`, default on).

## "Record this meeting?" prompt

The same scan also drives a proactive prompt (spec:
`superpowers/specs/2026-10-06-record-this-meeting-prompt.md`). The chip only helps a
user who is looking at Tome; the prompt reaches one who is looking at the meeting.

- **Evidence** is two-signal: a detected meeting for an app whose `ConferencingApp`
  entry has `promptsToRecord` (Teams only in v1) **and** that app running audio
  *output* (`AudioProcessInspector.outputRunningBundleIDs`, HAL query lane). Both must
  hold for 10 s. Output, not input: muted joins are common and a live call always has
  far-end audio, while the pre-join lobby has none. An unanswered HAL query is
  `.unknown` — it neither advances nor resets the sustain.
- **`MeetingJoinPolicy`** (`Models/`) is a pure reducer stepped once per 3 s tick, idle
  or not: one instance per call keyed by bundle ID; it prompts once; accept, decline, or
  a recording settle it; stopping a recording mid-call suppresses a new instance for
  30 s; 60 s without evidence ends the instance.
- **Surfaces**: a silent non-activating floating panel (`MeetingJoinPanelController`,
  on the shared `FloatingPromptPanel`; never key, follows hide-from-screen-share) and an
  actionable notification (`TOME_MEETING_JOIN_PROMPT`). **Record** is the Record
  button's exact call (`startSession(mode: .auto, detectedMeeting: suggestedMeeting)` —
  so the chip's ✕ and the auto-name switch still govern the filename). The panel hides
  after 60 s; the notification stays actionable until the call ends.
- Off-switch: **Settings ▸ Output ▸ Meeting Detection ▸ "Ask to record when a call is
  live"** (`AppSettings.promptToRecordDetectedMeetings`, default on). Nothing here
  ever starts a recording by itself.

## Limitations

- Heuristic, English-marker, active-tab-only (browsers); the ✕ is the safety net.
- Zoom and non-Teams/Meet apps yield no name in v1; the record prompt is Teams-only
  until each app's in-call audio signature is checked on a real call (`promptsToRecord`).
- Detection requires Screen Recording permission (already used for audio).
- Meeting titles are **never** logged (logging policy is metadata-only).

## Out of scope / follow-ons

- EventKit/calendar as a cleaner name + attendees source (`MeetingContext` already has
  `calendarEventId`/`attendees`).
- Auto-detect → prompt to start recording (see `ROADMAP.md`); this detection layer is
  the substrate for it.
