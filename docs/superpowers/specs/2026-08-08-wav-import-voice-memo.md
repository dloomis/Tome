# WAV Import — Treat an External Recording as a Native Voice Memo

**Date:** 2026-08-08
**Status:** Design — not yet implemented
**Scope:** Single-file `.wav` import (v1), architected for multi-file batch import (v2)

## 1. Summary

Let the user import a `.wav` voice-memo recording made on another device and have Tome
process it *exactly* as if it had been recorded natively as a voice memo: offline
transcription, post-session speaker diarization, and a finalized Markdown note (plus
optional retained `.m4a` and voiceprint sidecar) written to the configured voice-memo
output folder.

Two entry points: **File ▸ Import Audio…** and **drag-and-drop onto the main window**.
Non-audio and undecodable files are rejected with a clear message. Recording date/time
is derived from file metadata (creation date) plus audio duration.

### Design principle: synthesize the session, reuse the pipeline

Everything downstream of "a mic WAV in the sessions directory + a live-format transcript
note" already exists and is battle-tested: `PostProcessingJob` diarizes the mic WAV for
`sessionType == .voiceMemo`, rebuilds the body into `Speaker 1..N` when ≥2 speakers are
detected, keeps the live "You" transcript for a solo memo, exports retention audio,
emits voiceprints, cleans up capture files, and drives the save banner + notification.

So the import feature is deliberately small: an **import stage** that manufactures the
same two artifacts a native voice-memo session leaves behind at stop time, then enqueues
a completely ordinary `PostProcessingJob` on the existing `PostProcessingQueue`. No fork
of the diarization/finalize/retention/voiceprint logic, no divergent output format.

```
                       IMPORT STAGE (new)                          EXISTING PIPELINE (unchanged)
┌────────────┐   ┌──────────────────────────────┐   ┌─────────────────────────────────────────┐
│ File menu  │   │ 1 validate (UTType + decode) │   │ PostProcessingQueue (serial)            │
│    or      ├──►│ 2 copy → sessions/<sid>.mic. │──►│  PostProcessingJob (.voiceMemo)         │
│ drag-drop  │   │   wav  + sidecar             │   │   diarize mic WAV → re-transcribe       │
└────────────┘   │ 3 offline "live pass":       │   │   → rebuild Speaker 1..N (or keep       │
                 │   FileAudioReader →          │   │     solo "You") → finalize frontmatter  │
                 │   StreamingTranscriber →     │   │   → retention .m4a → voiceprints        │
                 │   dedicated TranscriptLogger │   │   → cleanup → save banner + notif       │
                 │   (live-format note + JSONL) │   └─────────────────────────────────────────┘
                 │ 4 endSession → SessionHandle │
                 └──────────────────────────────┘
```

## 2. Non-goals (v1)

- **Formats other than `.wav`.** The architecture reads audio via `AVAudioFile`, so
  `.m4a`/`.mp3`/`.aiff` are a one-line allowlist change later — but v1 accepts only
  files conforming to `UTType.wav`.
- **Multi-file import.** v1 imports one file per gesture. Everything is shaped so v2 is
  a UI/limit change, not a redesign (§9).
- **Call-capture import.** Imported audio is always a mic-only voice memo
  (`sessionType: .voiceMemo`). There is no "Them" leg to reconstruct.
- **Finder/Dock integration** (`CFBundleDocumentTypes`, "Open With Tome", dropping on
  the Dock icon). Future niceties; not v1.
- **Importing while a recording session is live.** Imports queue and start only when
  the app is idle (§7).

## Implementation note — model / effort assignments

This spec is intended to be executed with **Opus** doing the implementation work.
Baseline assignment is **Opus medium** — most of the spec is mechanical work against
explicit instructions. Three spots are assigned **Opus high**: think longer, re-read
the referenced source, and write the relevant §10 tests first. An orchestrator
delegating this work should split it so each high-effort spot is implemented (or at
minimum reviewed) in its own high-effort pass, not folded into a medium-effort sweep.

| Work | Model / effort | Why |
|---|---|---|
| **§6.1 `ImportJob` rollback / §8 failure semantics** | **Opus high** | Partial-failure logic is easy to invert: *zero* utterances → full unwind; *some* utterances → keep everything and hand off anyway. Getting this backwards either litters the vault or destroys a recoverable transcript. Tests first. |
| **§6.1 `FileAudioReader` backpressure** | **Opus high** | Must be `AsyncStream(unfolding:)` (pull-based). The natural-looking `AsyncStream { continuation in … }` producer-task shape compiles, works on short files, and silently buffers a 2-hour file into hundreds of MB. Verify laziness with the §10 no-read-past-consumed test, not by inspection. |
| **§7 gating + §6.2 `TranscriptLogger`/`StreamingTranscriber` edits** | **Opus high** | These touch the live-recording path. The optional parameters must be behavior-identical for every existing caller (default values, no reordering of `Date()` capture relative to flush/close), and the coordinator's idle checks race against `isSessionPending` windows — reason about the interleavings, don't pattern-match. |
| Everything else: validation gates, menu/drop wiring, timestamp derivation, `ImportCoordinator` scaffolding, handle construction, remaining §6.2 one-line edits, §10 tests for the above | **Opus medium** | Deliberately low-risk and fully specified. |

Regardless of assignment, treat §6.2's "explicitly **not** changed" list as binding:
no refactoring of `SessionType`, `TranscriptFinalizer`, `PostProcessingQueue`, or the
diarization pipeline, however tempting.

## 3. User experience

### 3.1 File menu

`File ▸ Import Audio…` (suggested shortcut ⌘I), placed in the existing
`CommandGroup(after: .saveItem)` next to *Recover from WAV…*.

**Constraint (macOS 26 menu crash):** the menu `Button` must be statically enabled and
invoke a callback registered in `AppServices` (`importAudioAction`), exactly like
`saveTranscriptAction` / `recoverFromWAVAction`. No `@FocusedValue`, no dynamic
`.disabled(...)`. The callback no-ops with `NSSound.beep()` + an explanatory error row
when import isn't currently possible (model not ready, recording live).

The action opens an `NSOpenPanel`:
- `allowedContentTypes = [.wav]`
- `allowsMultipleSelection = false` (v1 — flipping this to `true` is the v2 entry point)
- `canChooseDirectories = false`, resolves aliases/symlinks to the real file

### 3.2 Drag and drop

`ContentView`'s root gains `.onDrop(of: [.fileURL], isTargeted: $importDropTargeted)`.

- While a conforming drag hovers, show an overlay affordance ("Drop to import audio")
  over the transcript area; non-conforming drags are refused in `validateDrop` so the
  system shows the "not allowed" cursor.
- On drop, resolve the item to a file URL and funnel into the same
  `ImportCoordinator.enqueue(_:)` the menu uses. v1 takes the first conforming URL of a
  multi-item drop and reports "one file at a time for now" if more were dropped —
  the drop handler itself is already list-shaped for v2.
- The drop is ignored (overlay never shown) while onboarding is up or a session is
  pending/recording — same conditions under which the menu action no-ops.

### 3.3 Feedback during and after

- **Import stage:** a status row in `ContentView` (sibling of the existing job/save
  banner slot) shows the import phase and progress: *Validating… / Preparing… /
  Transcribing “REC0034” (42%)*, with a Cancel button. Progress is
  `framesConsumed / totalFrames` from the file reader — exact, since file length is
  known up front (unlike live capture).
- **Post-processing stage:** identical to a native memo — the existing
  `PostProcessingQueue` UI takes over (menu-bar icon pulse, phases, then the standard
  "Saved" banner with open-file action and the `UNUserNotification`). No new completion
  UI is built for import.
- **Failures:** an alert-style error row ("Couldn't import REC0034.wav: not a readable
  WAV file") plus a notification if the window is hidden. A failed or cancelled import
  rolls back everything it created (§8) — the user's original file is never touched.

## 4. Timestamp derivation

The note must be dated by when the audio was *recorded*, not when it was imported.

- `sessionStartTime = file creationDate` (most field recorders and phone memo apps
  stamp creation at recording start; AirDrop and Finder copies preserve it).
- `sessionEndTime = sessionStartTime + audioDuration`, where
  `audioDuration = file.length / file.processingFormat.sampleRate` via `AVAudioFile`
  (same math as `Recovery.inspectWAV`).
- Fallback chain when `creationDate` is missing or nonsensical (epoch 0, or in the
  future): `modificationDate − audioDuration` (the convention `Recovery.run` already
  uses), else `now − audioDuration`. Log which anchor was used via `diagLog`.

Consequences, all for free through existing code:
- The live note's filename date prefix is the recording date (backdated
  `startSession`, §6.2).
- Frontmatter `created:` and `duration:` are correct (`finalizeFrontmatter` computes
  duration as `sessionEndTime − sessionStartTime` = exact audio length, unaffected by
  queue latency).
- Per-line `#t=` offsets are `utterance.timestamp − sessionStartTime` = true audio
  position, because the offline pass anchors its audio clock at the derived start (§6.1).

## 5. Validation and safeguards

Layered, fail-fast, all before any artifact is created:

1. **Type gate.** URL must conform to `UTType.wav` (by declared content type, falling
   back to path extension). Images, PDFs, folders, etc. are rejected at the panel /
   `validateDrop` layer and never reach the pipeline.
2. **Decode gate.** `AVAudioFile(forReading:)` must succeed and report a PCM format
   with `sampleRate > 0`, `channelCount ≥ 1`, `length > 0`. A `.wav` extension on a
   renamed JPEG dies here with "not a readable WAV file".
3. **Duration bounds.** Reject `< 1.5 s` ("too short to transcribe" — below Parakeet's
   floor, mirroring `SegmentReTranscriber.minSamples`). Warn-and-proceed is *not*
   offered for absurd lengths; reject `> 8 h` outright ("too long to import") — beyond
   any plausible memo, and protects the retention mixer and diarizer from pathological
   inputs.
4. **Self-import guard.** Refuse files already inside
   `~/Library/Application Support/Tome/sessions/` or the configured output folders
   (someone dropping a Tome artifact back onto Tome).
5. **Copy-then-process.** The source is copied into the sessions directory before any
   processing (§6.2), so a source on removable/network storage can vanish mid-import
   without corrupting the pipeline. The original is **never** moved, modified, or
   deleted — cleanup at job success deletes only Tome's copy (existing
   `cleanupCaptureFiles` behavior, unchanged).
6. **Busy gate.** Import requires `modelProvisioner.canStartRecording` and no
   live/pending session (§7).

## 6. Architecture

### 6.1 New components

All under `Tome/Sources/Tome/Import/`.

**`FileAudioReader`** ⚠ *Opus high (see Implementation note)* — turns a WAV file
into the same thing live capture produces: an `AsyncStream<AVAudioPCMBuffer>`.

- Built with **`AsyncStream(unfolding:)`** so it is *pull-based*: each iteration of the
  consumer reads the next chunk from disk. This gives inherent backpressure — a 2-hour
  48 kHz file is never buffered in memory (an eagerly-yielding continuation would hold
  hundreds of MB), and the ASR pipeline paces the disk reads.
- Chunk size ~0.5 s of frames in the file's native format. No resampling here:
  `StreamingTranscriber.extractSamples` already converts any input format to 16 kHz
  mono Float32, exactly as it does for live mic buffers.
- Reports `framesConsumed` through a callback for the progress row.

**`ImportJob`** (`@Observable @MainActor`, mirrors `PostProcessingJob`'s shape) — one
file's import-stage state machine: `queued → validating → preparing → transcribing →
handedOff | failed(ImportError) | cancelled`. Holds the source URL, derived timestamps,
progress, and the rollback list. Identifiable so the (future) queue UI can show rows.

**`ImportCoordinator`** (`@MainActor`, owned by `AppServices`) — the serial consumer.

- `enqueue(_ urls: [URL])` — validates cheaply (type gate) and appends `ImportJob`s to
  a FIFO. v1 callers pass a single-element array; the coordinator is list-native from
  day one (v2 requirement).
- Drains the FIFO one job at a time, and only while no live session is active or
  pending (§7). Each job:
  1. **Validate** (§5 gates 2–4).
  2. **Prepare.** Mint `sid = SessionStore.generateSessionId()` and a session GUID;
     copy the source to `sessions/<sid>.mic.wav`; open a *dedicated* `SessionStore`
     instance for the crash-recovery JSONL; `startSession` on a *dedicated*
     `TranscriptLogger` instance (§6.3) with `sessionType: .voiceMemo`,
     `sourceApp: "Imported"`, the voice-memo vault path and filename label from
     settings, and the derived `startedAt` (§6.2); `updateContext(<original file
     stem>)` so the finalized filename carries the source recording's name; write the
     `SessionSidecar` pairing `<sid>.mic.wav` → transcript so a crash mid-import is
     recoverable by the existing launch-time `OrphanScanner`, like any other orphan.
  3. **Offline live pass.** Run a `StreamingTranscriber` (speaker `.you`, fresh
     `SileroVADStream`, shared `ASRCoordinator`) over `FileAudioReader`'s stream, with
     `baseTime` overridden to `sessionStartTime` (§6.2). `onFinal` appends each
     utterance to the dedicated logger + JSONL — the same fan-out the live path does —
     so the note on disk is a genuine live-format transcript with correct offsets.
     `onPartial` is dropped (no live UI for imports).
  4. **Hand off.** `endSession(endTime: sessionEndTime)` → snapshot → build a
     `SessionHandle` (`sessionType: .voiceMemo`, `micWavPath: <sid>.mic.wav`,
     `micFirstSampleTime: sessionStartTime`, `wavBufferPath: nil`,
     `origin: .imported`) and enqueue a standard `PostProcessingJob` on
     `services.postProcessingQueue` with the user's current diarization/retention/
     voiceprint settings — identical to `ContentView.stopSession`'s enqueue.

**Zero-speech outcome:** if the live pass produced no utterances (silent or non-speech
WAV), do **not** hand off. Roll back (delete note, JSONL, WAV copy, sidecar) and report
"No speech detected in REC0034.wav". This deliberately differs from a native session —
a user who consciously recorded silence still gets a note; an imported silent file is
almost certainly a mistake and must not litter the vault.

### 6.2 Small modifications to existing code

Each is a narrow, optional-parameter change — no behavior change for existing callers.
⚠ The `StreamingTranscriber` and `TranscriptLogger` rows touch the live-recording path:
prove behavior-identity for existing callers at Opus high (see Implementation note).

| File | Change | Why |
|---|---|---|
| `StreamingTranscriber.swift` | `init` gains `baseTime: Date? = nil`; `run()` uses it instead of `Date()` on first buffer | Anchors utterance timestamps / offsets at the derived recording start instead of import time |
| `TranscriptLogger.swift` | `startSession` gains `startedAt: Date = Date()`; `endSession` gains `endTime: Date = Date()` | Backdates the note's filename date prefix, frontmatter `created:`, offset math, and duration to the real recording window |
| `Models.swift` (`SessionHandle`) | new `enum SessionOrigin { case live, imported }`, `let origin: SessionOrigin = .live` | The one legitimate post-processing divergence (voiceprints, next row) |
| `PostProcessingJob.swift` | voiceprint sidecar for `.voiceMemo` emits `includesYou: origin == .live` | `includesYou: true` asserts the recording user is among the speaker prints; for a file recorded on another device Tome cannot attest that. Downstream (WhisperCal) must not bind a centroid to the user on that basis |
| `AppServices.swift` | `let importCoordinator: ImportCoordinator`; `@ObservationIgnored var importAudioAction: (() -> Void)?`; `var isImporting = false` | Menu-callback pattern (macOS 26 crash constraint) + model-picker lock (§7) |
| `TomeApp.swift` | `Button("Import Audio...")` in the `CommandGroup(after: .saveItem)` calling `services.importAudioAction` | Entry point |
| `ContentView.swift` | register `importAudioAction` in the boot task; `.onDrop` + overlay; import status row | Entry point + feedback |
| `SettingsView.swift` | fold `isImporting` into the existing model-picker lock (`isRecording / isSessionPending / isRecovering / isAnyJobRunning`) | A model swap must not land mid-import |

Explicitly **not** changed: `SessionType` (imports are `.voiceMemo` — adding a third
case would ripple through Codable artifacts, sidecars, and the API for no behavioral
gain), `TranscriptFinalizer`, `PostProcessingQueue`, diarization/re-transcription,
retention, `SystemAudioCapture`.

### 6.3 Why dedicated `TranscriptLogger` / `SessionStore` instances

`services.transcriptLogger` and `services.sessionStore` are single-session actors whose
"current session" state belongs to live recording. An import that claimed them would
block recording (or be corrupted by it). Both types are plain instantiable actors with
no global state — the import job creates its own short-lived instances, writing to the
same sessions directory and vault folders. The app-lifetime instances stay dedicated to
the live path, including the terminate-flush handler. (The `ASRCoordinator` and
`PostProcessingQueue` are the opposite: deliberately shared, because they are the
serialization points.)

### 6.4 Why an offline "live pass" instead of diarize-first

An alternative was to skip transcription and let the job's diarize → re-transcribe
rebuild produce the body. Rejected because the solo-memo path depends on a real live
transcript: a mic-only session with ≤1 detected speaker *keeps the live "You" body*
(no rebuild) — with a stub note, a solo imported memo would finalize empty. The live
pass also preserves exact parity of behavior and output (VAD segmentation, pre-roll
seeding, sanitization, per-line offsets) with a native memo, which is the stated goal.
The cost — the audio is transcribed once in the live pass and again per-segment after
diarization — is the same cost every native multi-speaker session already pays.

## 7. Interaction with live recording

⚠ *Opus high (see Implementation note): reason through the interleavings with
`isSessionPending` and a live start racing an in-flight import — don't pattern-match.*

- **Imports never run concurrently with a live session.** The coordinator starts a job
  only when `activeSessionType == nil` and `!services.isSessionPending`; enqueueing
  while recording is allowed (the job waits, the status row says "Waiting for the
  current recording to finish…").
- **A recording started mid-import does not cancel the import.** The in-flight import
  continues; its ASR chunks serialize with live streaming through `ASRCoordinator`
  exactly as background re-transcription already does during cross-session overlap.
  Contention is bounded to one ~30 s-chunk decode of added latency on live partials.
  The coordinator simply won't *start the next* queued job until idle again.
- `services.isImporting` is true while a job is validating/transcribing; Settings folds
  it into the model-picker lock so a backend swap can't land mid-import (same rationale
  as `isRecovering`, audit F-2/F-3 lineage).
- Import does not touch the engine, the mic, or the HAL at all — no device binds, no
  `HALQueue` traffic, no interaction with the wedge latch.

## 8. Failure handling and rollback

⚠ *Opus high (see Implementation note): the zero-vs-partial distinction below is
the easiest thing in this spec to invert. Write the §10 state-machine tests first.*

`ImportJob` keeps a rollback list of everything it created (WAV copy, sidecar, JSONL,
live note) and unwinds it on validation failure, decode/read error mid-pass, zero
speech, or user cancel — mirroring `rollbackFailedStart`'s guard: the note is deleted
only if no utterances landed in it; if the pass got partway, the artifacts are *kept*
and handed off anyway (partial transcript + full WAV → the post-processing job and, if
that later fails, the existing orphan scan / `.failed.json` marker machinery recover
it). The source file is untouched in every path.

Once handed off, failure semantics are entirely the existing job's: capture files
preserved on failure, `<sessionId>.failed.json` marker, orphan scan on next launch.
A crash mid-import is covered by the sidecar + JSONL written in the prepare step.

## 9. Multi-file import (v2 forward-design)

Locked in now so v2 is additive:

- **`ImportCoordinator.enqueue(_ urls: [URL])` is already list-shaped**; the FIFO,
  per-job isolation, and serial drain are the batch semantics ("process each in
  order"). v2 = flip `allowsMultipleSelection`, accept all conforming URLs from a
  drop, and render the queue (N rows or "Importing 3 of 10…" with per-file progress).
- **Failure isolation per file:** one bad file reports and rolls back; the queue moves
  on. A summary ("9 imported, 1 failed") replaces the single-file banner when a batch
  ran. Per-file results accumulate on the coordinator for that summary.
- **Ordering:** files process in the order given (panel selection order / drop order);
  each produces its own independent note, WAV copy, and post-processing job. Timestamp
  derivation is per-file, so a batch of memos lands correctly dated regardless of
  import order.
- **Backpressure between stages:** the import stage stays strictly serial, and each
  handed-off `PostProcessingJob` queues on the already-serial `PostProcessingQueue` —
  so a 10-file batch never runs more than one ASR/diarization workload at a time by
  construction. No new throttling needed.
- Cancel semantics in v2: cancel the current file (rolls back per §8) and drop the
  remainder of the queue, or skip just the current file — decide at v2 UI time.

## 10. Testing plan

Unit tests (`swift test`, no audio devices or models — same constraints as the
existing suites):

- **Timestamp derivation:** creation-date anchor, each fallback, future-dated and
  epoch-zero metadata → pure function, table-driven.
- **Validation gates:** wrong UTType, renamed-JPEG decode failure, sub-1.5 s file,
  self-import path guard (fixture WAVs generated in-test with `AVAudioFile`).
- **`FileAudioReader`:** chunk math, full-file coverage (sum of frames == file length),
  pull-based laziness (no read past the last consumed chunk), progress callbacks.
- **Backdated logger session:** `startSession(startedAt:)` filename prefix and
  frontmatter `created:`; `endSession(endTime:)` duration; offsets of appended
  utterances against the backdated start.
- **Import job state machine with a scripted transcriber seam** (the `VADStream`
  protocol precedent): zero-speech rollback, mid-pass failure keep-and-hand-off,
  cancel rollback, rollback-list completeness (temp dir diff before/after).
- **Handle construction:** `origin: .imported` → voiceprint `includesYou == false`;
  `micFirstSampleTime == sessionStartTime` so retention alignment pads nothing.
- **Coordinator gating:** enqueue-while-recording waits; live-start mid-import doesn't
  cancel; serial drain order for a multi-element enqueue (v2 semantics tested now).

Manual acceptance: import a real phone memo (solo → stays "You"; two-speaker → rebuilt
`Speaker 1/2`), verify note lands in the voice-memo folder dated to the recording,
retention `.m4a` plays, original file untouched, drag-drop overlay + rejection cursor,
menu no-op beep while recording.

## 11. Open questions (defaults chosen, flag if you disagree)

1. **`sourceApp: "Imported"`** in frontmatter (vs. keeping "Voice Memo"). Chosen so
   downstream tooling can distinguish provenance; the note *type* is still voice-memo.
2. **Finalized filename carries the original file stem** via `sessionContext` (e.g.
   `2026-08-01 09-30-14 REC0034.md`). Alternative — pure timestamp naming — loses the
   only human hook to the source recording.
3. **Silent imports are rejected**, not saved as empty notes (§6.1). Chosen for vault
   hygiene.
4. **⌘I** as the shortcut (unclaimed in the current commands block).
