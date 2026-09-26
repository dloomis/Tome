# Single Record Button — Resolve the Session Type at Stop, Not at Start

**Date:** 2026-09-26
**Status:** Implemented 2026-09-26 (see *Implementation notes* at the end)
**Type:** Feature (capture UX / session lifecycle)
**Prereq reading:** `2026-07-25-mixer-device-system-audio-capture.md` (device-mode
"Them" leg, `FeederDetection`), `2026-08-08-wav-import-voice-memo.md` (the
`SessionHandle` / `PostProcessingJob` hand-off this spec extends)

## Problem / Motivation

`ControlBar` offers two start buttons — **Call Capture** (⌘R) and **Voice Memo**
(⌘⇧R). Usage on the reference machine is ~95% Call Capture (manual or via the
API from WhisperCal) and ~5% Voice Memo, and the memo case is almost always one
specific scenario: a phone call on speaker, with the caller and the user both
picked up by the single microphone.

The user sometimes presses the wrong button. The two mistakes are not
symmetric:

| Mistake | Consequence | Recoverable? |
|---|---|---|
| Voice Memo pressed during a Zoom/Teams call | `engine.start(captureSystemAudio: false)` — the far end is **never captured**. No WAV, no diarization source, no transcript of the other party. | **No.** |
| Call Capture pressed during a phone-on-speaker call | Both legs captured. The system WAV is silent, so diarization on it yields nothing and the note keeps a single "You" block; it is filed as `type: meeting` in the meetings folder. | Yes — the mic WAV (`<sid>.mic.wav`, always written) holds everything a Voice Memo would have had. |

So the second button exists to make a choice the app cannot afford to get
wrong in one direction and can trivially fix in the other. The fix is to stop
asking: **always capture both legs, and resolve the session type at stop time
from evidence the session already collects.**

## Key insight

Every difference between the two modes today is either (a) locked at start or
(b) decided in the post-processing job:

| Locked at start (`ContentView.startSession`) | Decided at stop (`PostProcessingJob`) |
|---|---|
| `captureSystemAudio` (the unrecoverable one) | which WAV to diarize (`wavBufferPath` vs `micWavPath`) |
| output folder (`vaultMeetingsPath` / `vaultVoicePath`) | `speakerBase` (2 vs 1), `preserveYou` |
| frontmatter `type:` (`meeting` / `fleeting`), tags, `# Call Recording` heading | voiceprint `source` / `includesYou` |
| `source_app` label, filename type label | short-session discard (call only) |
| sidecar `sessionType` | solo-memo collapse (≤1 speaker keeps "You") |

Column (b) needs no change beyond being fed a *resolved* type. Column (a)
collapses to "capture both legs, write the note provisionally as a call
(the 95% case), and re-type + relocate the note in the memo case." Nothing
new has to be detected before recording starts.

## Design

### 1. Requested mode vs. resolved type

`SessionType` (`callCapture` / `voiceMemo`) stays exactly what it is: the
**resolved** type, `Codable`, stamped into sidecars, failure markers, handles
and notifications. It gains no third case — every persisted artifact keeps its
meaning.

A new request-time enum carries the user's (or API caller's) intent:

```swift
enum RecordingMode: String, Sendable, Codable {
    case auto          // the single button; resolve at stop
    case callCapture   // explicit — behaves exactly as today
    case voiceMemo     // explicit — behaves exactly as today (mic only)
}
```

`ContentView.startSession(type:)` becomes `startSession(mode:)`. Explicit modes
are a straight mapping to the current code paths. `.auto` runs the
call-capture start path (both legs, provisional call note) and remembers
`activeRequestedMode = .auto` alongside the provisional
`activeSessionType = .callCapture`, so every existing consumer of
`activeSessionType` (import idle probe, discard notice, silence prompt)
keeps working unchanged.

### 2. Capture — `.auto` always brings up both legs

`.auto` calls `engine.start(... captureSystemAudio: true, systemAudioSourceUID:
settings.systemAudioSourceUID)` exactly like Call Capture. Consequences:

- **Device mode** (reference machine, Wave Link `Transcriber` mix): the extra
  leg is one more CoreAudio input. No new permission, negligible cost.
- **SCK mode**: Screen Recording permission is now required for every
  single-button session. That is already the case for Call Capture today;
  the README permissions table gets a one-line update. A user who declines
  the permission gets today's SCK failure banner, the session continues
  mic-only, and resolution treats the leg as **unavailable** (see §3) — it
  never masquerades as "silent".
- The mic WAV and system WAV are both written, both sidecar-bearing
  (`SystemAudioCapture` emits the `<sid>.wav` sidecar as today), both handed
  to the job as today. `stopSession` already snapshots both paths for every
  session type.

### 3. Resolution — a pure function, run once at stop

House style (`resolveSystemSource`, `shouldReadoptMicDevice`,
`FeederDetection.verdict`): a pure, exhaustively tested function with no
engine access. `ContentView.stopSession` assembles the evidence and calls it
**before** building the `SessionHandle`, so the handle's `sessionType` is the
resolved type and everything downstream is unchanged.

```swift
struct SessionTypeEvidence: Sendable, Equatable {
    let requestedMode: RecordingMode
    /// API `meetingContext` / `suggestedFilename`, or an accepted MeetingDetector chip.
    let hasMeetingEvidence: Bool
    /// A *native* conferencing app (`ConferencingFamily` other than `.meetBrowser`)
    /// was frontmost at start. Browsers are excluded: Chrome frontmost during a
    /// phone-on-speaker call is the normal case, not call evidence.
    let nativeConferencingAppAtStart: Bool
    /// The "Them" leg bound and delivered at least one buffer
    /// (`systemFirstSampleTime != nil`). False = evidence UNAVAILABLE, not silent.
    let systemLegDelivered: Bool
    /// Device mode only; `.unfed` means the mix could not have carried a call.
    let feederVerdict: FeederVerdict?
    /// Final utterances attributed to "Them" with non-whitespace text.
    let themUtteranceCount: Int
}

enum SessionTypeResolution: Equatable {
    case explicit(SessionType)
    case call(reason: CallReason)          // .meetingEvidence, .conferencingApp, .farEndSpeech, .legUnavailable
    case voiceMemo(reason: MemoReason)     // .farEndSilent, .mixUnfed
    var sessionType: SessionType { … }
}

static func resolveSessionType(_ e: SessionTypeEvidence) -> SessionTypeResolution
```

Precedence, first match wins:

| # | Condition | Result | Why |
|---|---|---|---|
| 1 | `requestedMode != .auto` | `.explicit(that type)` | Explicit intent (API `callCapture`/`voiceMemo`, ⌘⇧R, Option-click) is never second-guessed. |
| 2 | `hasMeetingEvidence` | call `.meetingEvidence` | A named meeting is a meeting even if the far end never spoke (user presented the whole time). Must outrank audio silence. |
| 3 | `nativeConferencingAppAtStart` | call `.conferencingApp` | Zoom/Teams/FaceTime/Slack/Webex frontmost at start. Zoom exposes no topic, so rule 2 misses it. Browsers deliberately excluded. |
| 4 | `themUtteranceCount >= 1` | call `.farEndSpeech` | The far end said something transcribable. Chosen over RMS: a notification ding or hold music crosses `audibleRMSThreshold` but does not transcribe. Zero new instrumentation — `TranscriptStore` already has it. |
| 5 | `feederVerdict == .unfed` | memo `.mixUnfed` | The mixer wasn't running; the leg could not have carried a call. |
| 6 | `!systemLegDelivered` | call `.legUnavailable` | **Unanswered ≠ silent** (the 2026-07-27 lesson). A leg that never bound (permission declined, SCK failure, wedged HAL) is missing evidence, so fall back to the 95% base rate. The note is already a call note; nothing to relocate. |
| 7 | otherwise | memo `.farEndSilent` | The leg was live and nobody on it ever said a word: phone on speaker, in-person meeting, solo memo. |

The `reason` is logged (`[STOP] resolved <type> (<reason>)`) and surfaced in the
API status response so a mis-resolution can be diagnosed from File ▸ Logs
without transcript content.

**Evidence capture ordering in `stopSession`** (see Implementation note — this
is an interleaving, not a checklist):

- `systemFirstSampleTime`, `systemAudioSourceIsDevice`, the feeder verdict and
  the start-time signals are read **before** `engine.stop()`, as the existing
  telemetry snapshot already is (the engine may be reused by a new session
  immediately after).
- `themUtteranceCount` is read from `transcriptStore` **after** `engine.stop()`
  has drained the transcribers and `handleNewUtterance()` has run — the final
  "Them" utterance flushed at stop is only in the store after the drain.
  Reading it earlier makes a call whose only far-end line was the last one
  resolve as a memo.

### 4. The live note — provisional call, re-typed on demand

For `.auto`, the live note is written exactly as a Call Capture note is today
(meetings folder, `type: meeting`, `log/meeting` + `source/meeting` tags,
`# Call Recording — …` heading, call filename label, `source_app` from the
frontmost conferencing app or `"Call"`). This is deliberate:

- It is the correct outcome 95% of the time, with zero churn.
- WhisperCal's live-note flow (mid-session rename, frontmatter mutation,
  `source_file` relocation) keeps seeing what it sees today.

When resolution says `.voiceMemo` and the note was written provisionally, the
job's **first step** — before the short-session discard check and before
diarization, so it runs within seconds of stop — is a new finalizer step:

```swift
/// Re-type a provisionally-written call note as a voice memo and move it to the
/// voice folder. Returns the snapshot re-pointed at the new path. Content rewrite
/// is atomic-in-place FIRST; the cross-folder move is best-effort SECOND. A failed
/// move leaves a correctly-typed memo in the meetings folder (logged via
/// diagLogError), never a half-written file.
static func retypeAsVoiceMemo(
    snapshot: TranscriptSessionSnapshot,
    voiceFolder: URL,
    filenameTypeLabel: String       // settings.filenameVoiceLabel, snapshotted at start
) throws(PostProcessingError) -> TranscriptSessionSnapshot
```

It patches, using the same quote-tolerant `yamlField` matchers as
`rewriteFrontmatter` (WhisperCal may already have round-tripped the YAML):

| Field | From | To |
|---|---|---|
| `type:` | `meeting` | `fleeting` |
| `source_app:` | `"Call"` / app name | `"Voice Memo"` |
| tags | `log/meeting`, `source/meeting` | `log/voice`, `source/voice` |
| body heading | `# Call Recording — <date> <time>` | `# Voice Memo — <date> <time>` |
| `source_file:` + filename | `<date> <callLabel>.md` | `<date> <voiceLabel>.md` (only when the file still carries Tome's default call-label name; a WhisperCal- or context-renamed file keeps its name) |
| location | `vaultMeetingsPath` | `vaultVoicePath`, with the existing `-1, -2…` collision suffixing |

`finalizeFrontmatter` then runs unchanged on the relocated snapshot. A
`TranscriptSessionSnapshot` that was externally renamed mid-session
(`relocateRenamedNote`) is re-typed and moved under its external name — the
external pipeline chose that name deliberately.

If `retypeAsVoiceMemo` throws on the **content rewrite** (note unreadable —
vault unmounted), the job fails the same way any finalizer read failure does
today: WAVs kept, `<sid>.failed.json` marker, failure notification. The
provisional call note is left intact.

### 5. `PostProcessingJob` changes

- New `init` inputs: `provisionalRetype: RetypePlan?` (nil unless resolved memo
  from a provisional call note; carries `voiceFolder` + `filenameTypeLabel`).
- Step order: **retype → short-session discard → diarization → finalize →
  retention → cleanup**. Discard is keyed on `handle.sessionType` (resolved),
  so a resolved memo is never discarded, exactly as an explicit memo isn't
  today. `stopSession` computes `discardLimit` from the resolved type.
- Diarization plan: the existing `switch handle.sessionType` already does the
  right thing once `sessionType` is resolved — `.voiceMemo` diarizes
  `micWavPath` with `speakerBase = 1`, `preserveYou = false`, and the solo
  collapse keeps a single-speaker memo's "You" transcript. No change.
- `wavBufferPath` stays non-nil for a resolved memo so the (silent) system WAV
  is cleaned up / retained exactly as today. The retention mixer already
  handles both tracks; a silent track adds nothing audible.
- Voiceprints: `voiceprintIncludesYou` is `sessionType == .voiceMemo && origin
  == .live` — resolved type, so a phone-on-speaker session emits `source:
  "mic"`, `includesYou: true`. Correct: the user is one of the `Speaker N`
  prints.

### 6. Crash recovery / sidecar

The `<sid>.wav` sidecar is written at start with the **provisional** type
(`callCapture`). If the app crashes mid-session, the launch-time orphan scan
recovers it as a call: diarizes the system WAV, `preserveYou: true`. For a
session that was really a phone call the system WAV is silent, so the recovered
note keeps its live "You" transcript unsplit, filed as a meeting. **Degraded
but lossless** — the same outcome the wrong-button case produces today.

v1 ships that. Follow-up (tracked, not in scope): bump the sidecar to schema 3
with an optional `requestedMode`, and have the orphan scanner re-resolve an
`auto` sidecar from the session JSONL ("Them" line count) and the `.mic.wav`
companion before choosing `preserveYou`. Schema 2 sidecars must keep decoding.

### 7. UI

- `ControlBar` shows **one** full-width button: **Record** (⌘R, `record.circle`
  or `waveform.circle` glyph). The meeting chip and the mixer lean-in prompt sit
  above it unchanged.
- Explicit escape hatches, for the 5% you know in advance:
  - **⌘⇧R** keeps its meaning: start an explicit Voice Memo (mic only).
  - **Option-click** the Record button: same. The button's help text says so.
  - Both must stay statically enabled (macOS 26 menu-rebuild crash, see
    CLAUDE.md ▸ Keyboard Shortcuts); the ControlBar buttons already follow
    the callback pattern.
- Live label (`activeSessionLabel`): `.auto` shows `Recording · <meeting
  title | app>` or plain `Recording`; explicit modes keep today's labels.
- Save banner / completion notification already switch on the resolved
  `sessionType` (`"Meeting transcribed"` / `"Voice memo saved"`), so they report
  the resolution for free. Add the reason to the banner's tooltip only.
- The end-of-session "silent Them leg" note (`postSystemAudioSilent`, ≥60s,
  zero audible buffers) is **suppressed** when the session resolved to
  `.voiceMemo(.farEndSilent)` — a memo with a silent system leg is the expected
  outcome, not a fault. It still fires for `.call(.meetingEvidence)` /
  `.call(.conferencingApp)` with a silent leg (that IS the "is my mix wired?"
  case) and for explicit call captures.
- **Settings ▸ Output**: `Record button: Single (auto-detect) | Call Capture +
  Voice Memo`, default Single. The split layout is today's UI verbatim — a
  one-toggle rollback with no code removed.

### 8. API

- `StartSessionRequest.type` enum gains `"auto"`, and the field becomes
  **optional, defaulting to `auto`** (required → optional is backward
  compatible; existing callers sending `callCapture`/`voiceMemo` get explicit
  behavior, unchanged).
- `handleWhisperCalStart` keeps passing `.callCapture` explicitly. WhisperCal
  always knows it is starting a meeting.
- `GET /api/v1/sessions/{id}/status` gains `sessionType` (`callCapture` /
  `voiceMemo`) and `resolution` (the reason string) once the session leaves
  `recording`. Absent while recording. OpenAPI spec updated.
- Session state machine unchanged.

### 9. Logging

One `.notice` line at resolution: `[STOP] session type resolved:
<type> reason=<reason> them=<n> legDelivered=<bool> feeder=<verdict>
meeting=<bool> app=<bool>`. Counts and flags only — never transcript text. One
line per retype: `[JOB <id>] retyped provisional call note as voice memo →
<filename>` / `diagLogError` on a failed move.

## Edge cases

| Case | Outcome | Notes |
|---|---|---|
| Phone on speaker, Chrome frontmost, no calendar event | memo `.farEndSilent` | The target case. Browser frontmost is not call evidence. |
| Phone on speaker while a YouTube tab plays in the background | call `.farEndSpeech` | **Known false positive.** The video transcribes as "Them" and diarizes as Speaker 2. Mitigation: ⌘⇧R / Option-click. With retention on, the WAVs survive for a manual re-run via File ▸ Recover from WAV. Accepted for v1. |
| Zoom call, user talked the whole time, Zoom exposes no topic | call `.conferencingApp` | Rule 3. If Zoom was *not* frontmost at start (user pressed Record from Obsidian), this resolves memo — the note is re-typed and moved. Same transcript content either way; the user drags it back. Rare. |
| Teams call via API from WhisperCal | explicit call | Rule 1. Zero behavior change for the 95% path. |
| Screen Recording declined, SCK mode | call `.legUnavailable` | Rule 6. Note stays a call note; today's SCK failure banner shows. |
| Wave Link closed, device mode | memo `.mixUnfed` | Rule 5. The existing 0s unfed warning still fires at bind — it is correct advice. |
| In-person meeting, several people, one laptop mic | memo `.farEndSilent` | Diarizes the mic WAV into Speaker 1..N as today's Voice Memo does. |
| Explicit Voice Memo (⌘⇧R) during a Zoom call | explicit memo, far end lost | Unchanged from today. The escape hatch is the one place the old mistake survives, by design. |
| WhisperCal renames the provisional note mid-session, then it resolves memo | re-typed and moved under WhisperCal's name | `relocateRenamedNote` runs before the job as today; retype keeps the external name. See open question 1. |
| Vault voice folder unwritable at retype | memo metadata written in place, move fails, `diagLogError` | Note stays in the meetings folder with `type: fleeting`. Not a job failure. |

## Non-goals

- No post-hoc "actually this was a memo" toggle in the save banner (the job
  deletes the WAVs when retention is off; re-running needs them). Retention +
  Recover from WAV covers it for now.
- No change to explicit-mode behavior, WhisperCal's start path, the
  diarization plan, voiceprint contracts, or the note format.
- No acoustic/ML classification of the audio. The evidence is metadata the
  session already produces.
- Orphan-scan re-resolution (§6 follow-up).

## Tests (`Tome/Tests/TomeTests/`)

1. **`SessionTypeResolverTests`** — full truth table over the seven rules, plus:
   explicit mode ignores every other field; `!systemLegDelivered` with no
   other evidence → call, never memo; `themUtteranceCount == 0` +
   `systemLegDelivered` + no evidence → memo; browser-frontmost never
   contributes.
2. **`TranscriptFinalizerRetypeTests`** — fixture provisional call note →
   every patched field, tags, heading; default-label filename renamed,
   context-renamed filename preserved; WhisperCal-style unquoted YAML still
   patches; move collision suffixing; unwritable destination leaves a
   re-typed file in place and returns the original path; unreadable source
   throws `PostProcessingError` and leaves the note byte-identical.
3. **`PostProcessingJobTests`** — retype runs before discard and diarization;
   a resolved memo with `discardIfShorterThanOrEqual` set is never discarded;
   `wavBufferPath` still cleaned up for a resolved memo; failed retype read →
   `.failed.json` marker, WAVs kept.
4. **`APIServerTests`** — `type` omitted → auto; `"auto"` accepted; invalid
   string still 400; status exposes `sessionType` + `resolution` after stop.
5. **Sidecar** — schema 2 decodes unchanged (guards the §6 follow-up).

## Manual acceptance (reference machine, device mode)

1. Single button, Zoom/Teams call with far-end speech → note in meetings folder,
   `type: meeting`, Speaker 2..N split, "Meeting transcribed".
2. Single button, phone on speaker, nothing else playing → note in voice
   folder, `type: fleeting`, Speaker 1..N from the mic, "Voice memo saved", no
   silent-leg nag.
3. Single button, WhisperCal-started meeting where only you speak → stays a
   meeting (rule 2).
4. ⌘⇧R phone call → identical to today's Voice Memo.
5. Kill Tome mid single-button session → orphan scan recovers a call note
   with the "You" transcript intact.
6. Settings toggle back to split buttons → today's UI.

## Open questions / risks

1. **WhisperCal and the provisional note.** For the seconds between stop and
   retype (and the whole live session), a phone call is a `type: meeting`,
   `status/inbox` note in the meetings folder. If WhisperCal's pipeline acts on
   live notes (rather than waiting for `duration` to be finalized), it could
   link or process a note that is about to move. **Verify WhisperCal's trigger
   condition before implementing §4.** If it does act early, add a
   `tome_status: recording` frontmatter key that WhisperCal ignores until it
   flips — or defer the move and only re-type in place.
2. **Rule 4 threshold.** One transcribable "Them" utterance is the proposed
   bar. If stray system audio (a Slack notification voice, an ad) proves to
   flip phone calls into meetings in practice, raise it to a minimum count or
   a minimum summed duration — both are pure-function constants.
3. **Sidecar provisional type** (§6) — degraded-but-lossless is accepted for
   v1; confirm that's acceptable before shipping without the follow-up.

## Implementation note — model / effort assignments

This spec is intended to be executed with **Opus** doing the implementation
work, Fable orchestrating. Baseline is **Opus medium** — most of the change is
plumbing against explicit instructions. Three spots are **Opus high**: reason
about interleavings and failure ordering, tests first, in their own pass, not
folded into a medium sweep.

| Work | Model / effort | Why |
|---|---|---|
| **§3 `resolveSessionType` + the evidence snapshot ordering in `stopSession`** | **Opus high** | The precedence table encodes an epistemic rule the codebase has been burned by twice (unavailable ≠ silent). And `themUtteranceCount` must be read *after* the engine drain while engine telemetry must be read *before* `engine.stop()` — the two reads straddle an `await` on a path that a new session can enter immediately. Get the truth-table tests green before touching `stopSession`. |
| **§4 `retypeAsVoiceMemo`** | **Opus high** | A destructive path on the user's vault: in-place atomic rewrite first, best-effort move second, never the reverse; quote-tolerant matchers; external-rename preservation; collision suffixing; partial-failure semantics that leave a valid note at *some* path in every branch. Fixture-driven tests before implementation. |
| **§5 job step ordering + discard keyed on resolved type** | **Opus high** | Retype must precede discard and diarization, and a resolved memo must be un-discardable, or a 20-second phone call is silently deleted by the meetings-only discard policy. Small diff, easy to get backwards. |
| Everything else: `RecordingMode` enum, `startSession(mode:)` mapping, `ControlBar` single button + Option-click/⌘⇧R, Settings toggle, `activeSessionLabel`, silent-leg note suppression, API `auto` + status fields + OpenAPI, logging lines, README/CLAUDE.md updates, tests for the above | **Opus medium** | Mechanical and fully specified. |

## Implementation notes (2026-09-26)

Shipped as specified, with these resolutions and deviations:

- **Open question 1 — verified against the WhisperCal source.** WhisperCal's
  recording-tied link step (`ApiRecording.waitAndLink`) waits for the by-guid
  state `complete`, so a WhisperCal-started session (always explicit
  `callCapture`) is never touched early. Its *unlinked transcripts* auto-linker
  (`CalendarView.autoLinkObvious` → `ApiUnlinkedProvider.linkToNote`) does NOT
  wait: with `recordingSource: "api"` it can link and rename a live Tome note in
  the transcripts folder mid-session by `session_guid` or by a calendar-event
  heuristic, writing `meeting_note:` / `pipeline_state:` into the frontmatter.
  It never moves notes between folders and never reads `duration`, `type`,
  `status/inbox` or `tome_status`. Mitigation shipped: `retypeAsVoiceMemo`
  re-types a note carrying `meeting_note:` or `pipeline_state:` **in place**
  and neither renames nor moves it. (The reference machine currently has
  `recordingSource: "macwhisper"`, so this path is inactive there.)
- **Open question 2** — rule 4's threshold is the literal `>= 1` in
  `SessionTypeResolver.resolveSessionType`; raise it there if stray system
  audio proves to flip phone calls.
- **Open question 3** — improved on: at retype the job re-points **both**
  capture sidecars (`<sid>.wav` and `<sid>.mic.wav`) at the relocated note and
  stamps them `sessionType: voiceMemo`, so a crash during the diarization that
  follows recovers as a memo at the right path instead of rebuilding a
  duplicate meeting note. The sidecar written at *start* still carries the
  provisional `callCapture` (a crash mid-recording recovers as a call —
  degraded but lossless); schema unchanged, schema-2 decode test guards the
  follow-up.
- `retypeAsVoiceMemo` takes a `RetypePlan` (voice folder + both filename
  labels, snapshotted at stop) instead of two loose parameters; the call label
  is needed to recognize Tome's own default name. A second overload with a
  `moveItem` seam exists for the move-failure tests only.
- Rename rule: the note is renamed only when `suggestedFilename == nil`, the
  session context is empty, and the stem is exactly the default call-label stem
  (optionally `-N`), computed by the shared
  `FilenameSanitizer.defaultTranscriptStem` the logger also uses. Both filename
  labels are snapshotted at **start** (`ActiveSessionIntent`), matching the
  name the logger actually wrote. On a failed cross-folder move the finalizer
  falls back to a same-folder rename so a Tome-named memo still carries the
  voice label.
- Write/move order: the first atomic in-place write patches type / source_app
  / tags / heading and leaves `source_file:` untouched; the move follows; only
  then is `source_file:` patched (best-effort, non-fatal) to the final
  basename. So at every quiescent point `source_file:` names a file the note
  actually is — except a crash between the cross-folder move and that last
  patch, which `relocateRenamedNote` cannot follow across folders (documented
  in code).
- An empty `vaultVoicePath` setting makes the retype an in-place re-type (no
  move) rather than resolving a relative path.
- `APIServer.sessionDidResolve(id:sessionType:resolution:)` is called from
  inside `stopSession`'s Task after the drain (necessarily after
  `sessionDidStop`); it keys by session id and survives stop/complete until the
  5s eviction. Both status endpoints expose `sessionType` + `resolution`.
- `TranscriptionEngine.systemLegFeederVerdict` records the device leg's verdict
  at bind and on each silence tick, and is forced to `.fed` the moment the
  device delivers non-zero samples (a bind-time `.unfed` from hitting Record
  before launching Wave Link is revised once the mixer comes up). nil for
  SCK/mic-only. Not cleared by `stop()` (same reasoning as `systemSourceMode`).
- Per-session intent (`mode`, meeting evidence, native conferencing app, both
  filename labels) lives in one `ActiveSessionIntent` value set once at start
  and consumed once at stop; `activeSessionType` stays the provisional type for
  existing consumers.
- Evidence read order in `stopSession`: engine telemetry → `engine.stop()` →
  `handleNewUtterance()` → `themUtteranceCount` (no suspension between the
  last two) → resolve → flush/endSession → handle + job.
- Tests: `SessionTypeResolverTests` (35), `TranscriptFinalizerRetypeTests`
  (28), `DefaultTranscriptStemTests`, `PostProcessingJobTests` (+12),
  `APIServerTests` (+6), `SessionSidecarTests` (+3), `StopEvidenceTests` (9).
  Full suite 414/414 after a `/code-review high` pass whose findings were all
  addressed.
- Manual acceptance on the reference machine (device mode) is still owed —
  including confirming that ⌘⇧R fires in single-button mode (the hidden
  shortcut carrier in `ControlBar`) and the "Record before Wave Link" verdict
  revision.
