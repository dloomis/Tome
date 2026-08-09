# WAV Import — Code Review Findings (2026-08-08)

**Source:** high-effort multi-agent review of the working-tree implementation of
`2026-08-08-wav-import-voice-memo.md` (27 review agents; finder angles + independent
verification per finding). Implementation state at review time: clean build, 309 tests
in 46 suites passing.

**Status: ALL 10 FIXED (2026-08-09).** Applied in the working tree: import ids carry an
`-import` namespace marker (1); validation I/O runs off the main actor (2); a missing
sessions directory refuses the import instead of falling back to temp (3); `cancelAll`
drains the queue before per-job bookkeeping (4); imported memos emit voiceprint
`source: "imported"` and docs/voiceprints.md documents the key-on-`includesYou` contract
(5); partial hand-offs stamp the end time at the last consumed frame (6); `validateDrop`
requires WAV conformance (7); `canImportAudio` includes `isRecovering` with its own
reason text (8); the multi-file notice renders informational, not error-styled (9); a
mid-pass read failure reports "import was interrupted" via `ImportError.interrupted`
(10). Regression tests added for 1, 3, 4, 6, 10. Findings are ranked most-severe first;
line numbers refer to the working tree as of the review, pre-fix.

Beyond the 10 below, the review confirmed six lower-severity cleanup findings
(duplication/boilerplate) that fell below the report cap — re-run `/simplify` or a
low-effort review pass if you want them enumerated.

---

## 1. Import session id can collide with a live session (CONFIRMED, correctness)

`Tome/Sources/Tome/Import/ImportCoordinator.swift:415`

`uniqueSessionId` only checks files already on disk, but a native recording started
while the import is running mints the same second-resolution `session_...` id — the
engine writes its own `<sid>.mic.wav` (`TranscriptionEngine.swift:346`) and appends to
`<sid>.jsonl` (`SessionStore.startSession` deliberately appends to an existing journal)
in the same sessions directory.

**Failure:** user drops a WAV and, within the same wall-clock second, presses Record
(imports explicitly allow a live session to start mid-import). Both sessions share the
`<sid>` stem: the live mic WAV writer opens/overwrites the import's copy while
`FileAudioReader` is streaming it, and both sessions interleave writes into one JSONL.
The import transcribes corrupted/changing audio and post-processing diarizes the wrong
file — silent data corruption of both sessions. CLAUDE.md's invariant ("a colliding new
session must rotate, not append") is enforced only import→disk, not live→import.

## 2. Import validation does blocking I/O on the main thread (CONFIRMED, correctness)

`Tome/Sources/Tome/Import/ImportCoordinator.swift:391`

`ImportCoordinator.run` is `@MainActor` and calls `ImportSupport.inspectAudioFile`
(`AVAudioFile(forReading:)` open + header decode) and `fileDates` synchronously on the
main thread against the user's *original* file, which typically lives on
removable/network media at import time.

**Failure:** dragging a WAV from an SMB share / SD card / unmounting volume blocks the
main thread and beachballs the whole app — including the live-recording UI and every
recovery mechanism — exactly the hang class the HALQueue work (2026-07-25) eliminated.
Only the `copyItem` step was moved off the main actor; the decode gate touching the same
foreign volume was not.

## 3. Sessions-dir failure silently falls back to temp dir (CONFIRMED, correctness)

`Tome/Sources/Tome/App/AppServices.swift:118`

When `SystemAudioCapture.sessionsDirectory()` throws, the import environment silently
falls back to `FileManager.temporaryDirectory/"Tome/sessions"` — a directory the
launch-time `OrphanScanner` and crash-recovery machinery never look at.

**Failure:** if Application Support is unwritable, an import proceeds writing its WAV
copy, crash-recovery JSONL, and sidecar into temp instead of refusing. A crash mid-import
leaves artifacts where the orphan scan never looks (and macOS periodically purges), so
the interrupted import is silently unrecoverable — defeating exactly the crash-recovery
path the sidecar+JSONL exist for. The vault-path guard in `run()` refuses a missing
destination; this case needs the equivalent refusal.

## 4. cancelAll can start a job the user just cancelled (CONFIRMED, correctness)

`Tome/Sources/Tome/Import/ImportCoordinator.swift:330` (also `:327`)

`cancelAll()` iterates queued jobs through `cancel(_:)`, and each cancel calls
`startNextIfPossible()`, which can promote a later still-pending job to active before its
own cancel call runs.

**Failure:** `activeJob == nil`, `pendingJobs = [A, B]`, waiting banner showing, and
`isIdle()` just became true without a poke (e.g. held only by
`modelProvisioner.canStartRecording` or `isRecovering`, which flip without firing
ContentView's importSignal onChange; the 1s backstop hasn't fired). Cancel-all →
`cancel(A)` removes A and calls `startNextIfPossible`, which commits B as active; the
subsequent `cancel(B)` only sets B's token. B then runs full validate + prepare — copies
the WAV into `sessions/`, creates a vault note, writes JSONL and sidecar — before the
pass notices the token and unwinds. The user who pressed Cancel watches an import start,
files appear and disappear, and a spurious cancelled result gets recorded.

## 5. Imported memo voiceprint sidecar: `source: "mic"` with `includesYou: false` (PLAUSIBLE, correctness)

`Tome/Sources/Tome/Transcription/PostProcessingJob.swift:166`

The change from unconditional `voiceprintIncludesYou = true` breaks the historical
invariant that a sidecar with `source: "mic"` always asserts `includesYou: true` —
imported memos now emit `(source: "mic", includesYou: false)` while `voiceprintSource`
stays hardcoded `"mic"`.

**Failure:** a downstream consumer (e.g. WhisperCal) written against the documented
pre-import contract keys on `source == "mic"` to decide the recording user is among the
`Speaker N` prints. An imported WAV recorded on another device then binds a stranger's
centroid to the user's identity, and later meetings mis-tag that stranger as the user.
Fix direction: a distinct source value (e.g. `"imported"`) and/or update
`docs/voiceprints.md` + downstream consumers to key on `includesYou`, not `source`.

## 6. Partial hand-off stamps full audio duration (CONFIRMED, correctness)

`Tome/Sources/Tome/Import/ImportCoordinator.swift:504`

`endSession(endTime: stamps.end)` stamps the full audio duration even when the pass was
cancelled or read-failed partway with utterances landed (the hand-off-on-partial path),
so the snapshot's recording window claims audio that was never transcribed.

**Failure:** cancel a 60-minute import after 2 minutes with a few utterances committed:
the kept note finalizes with `duration: "60:00"` for 2 minutes of text — and for a solo
memo (≤1 diarized speaker) the body is never rebuilt, permanently misrepresenting 58
minutes as covered. End time should be derived from the last consumed frame
(`start + framesConsumed/sampleRate`) on partial paths.

## 7. validateDrop accepts every file drag, not just WAV (CONFIRMED, correctness)

`Tome/Sources/Tome/Views/ContentView.swift:1746`

`ImportDropDelegate.validateDrop` only checks conformance to `.fileURL`, so every file
drag is accepted — contradicting the delegate's own comment and spec §3.2 (a PDF/folder
drag must get the system "not allowed" cursor).

**Failure:** dragging a PDF shows the "Drop to import audio" overlay inviting the drop,
then a red "can only import .wav" error row — instead of the refusal cursor and no
overlay. `validateDrop` should also require conformance to
`ImportSupport.acceptedContentTypes`.

## 8. canImportAudio omits isRecovering; the two gates disagree (CONFIRMED, correctness)

`Tome/Sources/Tome/Views/ContentView.swift:722`

`canImportAudio` omits `services.isRecovering` while the coordinator's
`AppServices.importCanStart` gate includes it.

**Failure:** during a File ▸ Recover from WAV run, ⌘I / drop passes the ContentView gate
and enqueues, but the coordinator's idle probe returns false — the UI shows "Waiting for
the current recording to finish…" indefinitely while nothing is recording. Wrong cause
named, no hint that finishing recovery releases it.

## 9. Multi-file notice renders error-styled after completion (CONFIRMED, correctness)

`Tome/Sources/Tome/Views/ContentView.swift:781`

The informational "Importing X — one file at a time for now." message lands in
`importNotice`, which `importStatusRow` renders only in its failure styling (red warning
triangle) and only after the active-job banner clears.

**Failure:** drop two WAVs → during the import the banner hides the notice; when the
import finishes, a red error-styled "Importing A.wav — one file at a time for now."
appears for the rest of its 12s window, after the import already completed — reading as
an error and an in-progress state, neither true.

## 10. Mid-pass read failure blamed on the recording (CONFIRMED, correctness)

`Tome/Sources/Tome/Import/ImportJob.swift:200`

`ImportJob.disposition` maps a mid-pass `.readFailed` with zero utterances to
`ImportError.notReadable` ("not a readable WAV file") — but this path is only reachable
after the file already passed the decode gate and `FileAudioReader.init`, so the message
blames the recording for what is typically an I/O interruption on Tome's own copy.

**Failure:** a disk I/O error interrupts reading Tome's sessions-directory copy of a
perfectly valid WAV before the first utterance: the user is told their recording isn't a
readable WAV, may conclude the original is corrupt and delete it — when a retry would
succeed. Needs a distinct "import was interrupted, try again" message.
