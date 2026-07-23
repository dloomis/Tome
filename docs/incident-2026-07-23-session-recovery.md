# Incident report: 2026-07-23 morning call — transcript never written, session manually recovered

**Status:** Data fully recovered (manually), diarization backfilled. Root cause confirmed. **PATCHED 2026-07-23** — see the "Patch session results" addendum at the bottom; the "zero diagnostics" finding (§3) was an investigation artifact, not a defect.

## Summary

The 2026-07-23 10:01 am call capture (`session_2026-07-23_10-01-10`, GUID `7f235ab3-4b07-42e2-9d21-82f8fd20df73`, Tome 1.5.1, 53.5 min, ended ~10:54) produced **no transcript file in the vault** and its post-processing never completed: both session WAV buffers were left in the sessions directory and no save banner fired. The app did not crash.

**Root cause (confirmed):** WhisperCal started the meeting (which started the Tome recording); the user postponed and deleted the meeting note in WhisperCal — **a supported user action** — which also removed Tome's live transcript .md mid-session; the meeting was then re-initiated. The bug is Tome's response: it surfaced "Transcript file disappeared — vault may be unmounted" but took no corrective action, and `TranscriptLogger` kept writing through its retained `FileHandle` into the now-unlinked inode (APFS keeps the handle valid after unlink), so every append "succeeded" while producing no durable file. At stop, finalize couldn't read the markdown and the job aborted with additional errors and no output. **Intended behavior:** when the linkage breaks mid-session, Tome should carry on as an *unlinked meeting* — recreate the transcript file and record/diarize/store as usual. Recovery was done manually from the crash-recovery JSONL and the leftover WAV buffers (see below).

## Timeline (local time, 2026-07-23)

| Time | Event | Evidence |
|---|---|---|
| 04:36:17 | Tome (PID 1427, v1.5.1) launched | `ps -p 1427 -o lstart=` |
| 04:36 | `~/Library/Application Support/Tome/last-crash.log` written, **0 bytes** | file mtime — same second as launch; suggests a crash-handler/relaunch cycle overnight |
| 10:00 | `api-port` file rewritten | mtime — despite process having started at 04:36 (API server rebind? worth checking why) |
| 10:01:10 | Session started via WhisperCal (`callCapture`, `sourceApp: Call`); live transcript .md created in vault | `session_2026-07-23_10-01-10.session.json` |
| ~10:01–10:08 | Meeting postponed; user **deleted the note in WhisperCal → live transcript .md deleted**; meeting re-initiated when participant arrived; Tome showed "Transcript file disappeared — vault may be unmounted" and kept recording | user account; `TranscriptLogger.flushIfNeeded` vault-disappeared check (`TranscriptLogger.swift:180`) |
| 10:08:12 | First utterance in JSONL | first line timestamp `14:08:12Z` (~7 min of pre-meeting time) |
| 10:54:30 | Last utterance ("See ya") — normal meeting end, then user stopped recording | last JSONL line; WAV/JSONL mtimes 10:54 |
| 10:54+ | Post-processing evidently ran and failed silently: no markdown finalized, WAV buffers never cleaned up | both WAVs still present hours later; vault empty |

## Evidence collected

### 1. The live transcript file never existed in the vault

`session.json` declares `transcriptPath` = `.../SDA/Transcripts/2026-07-23 10-01-10 Call Recording.md` (inside the iCloud Drive Obsidian vault, `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SDA/`).

- No file with today's date anywhere under `SDA/` except the unrelated daily note (`find SDA -name "*2026-07-23*"` — includes dotfolders, so Obsidian's `.trash` too).
- `grep -rl 7f235ab3-4b07-42e2-9d21-82f8fd20df73 SDA/` → **zero hits**. The session GUID goes into live frontmatter, so if the file had ever been written and then renamed/moved by WhisperCal, the GUID search should find it. It found nothing.
- `~/.Trash`: nothing matching.

Resolved: the file **was** created at session start and then unlinked by the WhisperCal note deletion. The 432 subsequent appends all "succeeded" — `flushBuffer` writes through the retained `FileHandle`, which APFS keeps valid after unlink, so the data went into an orphaned inode and vanished when the handle closed. No write error ever fired (hence no `diagLog` from the write path), and the GUID search found nothing because the file no longer had a path. This is the sibling of the known WhisperCal mid-session-rename failure — same class (external mutation of the live transcript mid-session), but deletion instead of rename, and strictly worse because the data is unrecoverable from the vault side.

### 2. Post-processing failed without any user-visible signal

- Both buffers remained: `session_2026-07-23_10-01-10.wav` (system, 616 MB, Float32 mono 48 kHz, 3210.78 s) and `session_2026-07-23_10-01-10.mic.wav` (616 MB, 3210.90 s). `PostProcessingJob` only reaches `SystemAudioCapture.cleanupBufferFile` after finalize succeeds, so the job aborted partway.
- If the live markdown never existed, `TranscriptFinalizer.rebuildFromDiarizedSegments` / `finalizeFrontmatter` would fail on read (consistent with `markdownReadFailed`) — i.e. the post-processing failure is probably **downstream** of the missing live file, not a separate bug.
- No completion banner / `UNUserNotification` fired, and apparently no *failure* notification exists either — the session vanished without the user being told.

### 3. Zero diagnostics — the logging path produced nothing

- `log show --predicate 'subsystem == "io.gremble.tome"'` over the whole session window (09:55–11:05): **0 entries**.
- `log show --last 12h --predicate 'process == "Tome"'`: **0 entries**.
- `/tmp/tome.log` does not exist (correct — that writer was removed), and `last-crash.log` is empty.

`diagLog(_:)` logs at `.notice`, which *should* persist to the log store. Zero entries for the entire process means the release build's logging is not reaching the persisted store at all — so even after this bug is understood, File ▸ Logs would have shown nothing. This is a second, independent defect (or at minimum a diagnosis blocker) and should be verified first in the patch session, since fixing it is what makes the next occurrence debuggable.

### 4. App/environment state

- Tome 1.5.1, PID 1427, launched 04:36:17, still alive and responsive after the incident (no crash report in `~/Library/Logs/DiagnosticReports/`).
- The 04:36 launch + simultaneous empty `last-crash.log` suggests something happened overnight (crash + auto-relaunch? Sparkle update relaunch?). Whether the 04:36 instance was in a degraded state by 10:01 is an open question.
- Vault is on iCloud Drive. iCloud eviction/dataless-file behavior on the Transcripts directory is a candidate for why a file create/append could fail.

## Recovery performed (2026-07-23, this session)

Raw data sources — both intact:
- `~/Library/Application Support/Tome/sessions/session_2026-07-23_10-01-10.jsonl` — 432 utterances, `{speaker: you|them, text, timestamp}` per line, 14:08:12Z–14:54:30Z.
- The two WAV buffers listed above.

Recovered artifacts written to the vault:
1. **`SDA/Transcripts/2026-07-23 10-01-10 Call Recording.md`** — rebuilt via a Python script: JSONL entries sorted by timestamp, rendered as `**You**/**Them** (offset-seconds)` blocks with Tome-style YAML frontmatter (type/created/time/duration 53:31/source_app/recording link/session_guid/tags), plus `recovered: true` and a `recovery_note`. Speaker labels are the raw live `You`/`Them` — **diarization was never run**, so no `Speaker 2..N` split and no `.voiceprints.json` sidecar.
2. **`SDA/Audio/2026-07-23 10-01-10 Call Recording.m4a`** (94 MB, 53:31) — both mono WAVs overlaid into one AAC file via a throwaway Swift script (`AVMutableComposition` with two audio tracks + `AVAssetExportSession` `AppleM4A` preset), matching Tome's retained-recording convention.

**The original WAV buffers were deliberately NOT deleted** — they are the only source if we want to run proper diarization on this session later. They're ~1.2 GB in `~/Library/Application Support/Tome/sessions/`; safe to delete once diarization is done or deemed unnecessary.

## Patch plan for the fix session

1. **Self-heal on transcript disappearance (the core fix).** External deletion of the live transcript is a *legitimate event* (the user deleting a WhisperCal meeting note is supported), and Tome's contract is: when the linkage breaks mid-session, continue as an **unlinked meeting** — record, diarize, and store the transcript as usual. `TranscriptLogger.flushIfNeeded` (`TranscriptLogger.swift:180-183`) already detects the unlinked file but only sets `lastError` — the retained `FileHandle` keeps writing into the orphaned inode forever. On detection (and defensively on any flush): close the handle, recreate the file (frontmatter + full utterance history), and continue; downstream post-processing then works unchanged. The full history isn't in `utteranceBuffer` (cleared per flush) — replay it from the session JSONL (`SessionStore`), which this incident proved is a complete, sufficient record. Consider also running the existence check inside `append()`'s flush path rather than only on the timer cadence.
2. **Finalize fallback from JSONL.** When `TranscriptFinalizer` can't read the live markdown at stop (this incident, and the WhisperCal rename race), rebuild the body from the session JSONL instead of failing the whole job — then diarization, sidecar, and buffer cleanup all proceed normally.
3. **Surface post-processing failure to the user.** `PostProcessingQueue` should distinguish success/failure in `lastCompletion` and post a *failure* notification naming the session ("errors with no transcript written" was the entire UX here). A failed job should leave a machine-readable failure marker next to the JSONL so recovery tooling can find it.
4. **No WhisperCal changes required.** Deleting transcripts/notes from WhisperCal is intended user behavior; nothing here imputes a WhisperCal bug or workflow change. The fix is entirely Tome-side resilience (item 1).
5. **Fix the logging blackout.** Verify in a release build that `diagLog` `.notice` messages actually persist (`log show --predicate 'subsystem == "io.gremble.tome"'` returned **zero entries over 12h** — even session-start messages). Independent of this incident, it makes field incidents undiagnosable. Log transcript-disappearance and write failures at `.error`/`.fault`.
6. **Extend `Recovery.swift` to JSONL-first recovery.** `File ▸ Recover from WAV…` re-runs diarize → re-transcribe → rebuild on an orphaned WAV + transcript pair, but presumes the transcript .md exists; this incident's failure mode (markdown unlinked) leaves it nothing to pair with. Rebuilding the .md from the session JSONL first would make it cover this case end to end.
7. **(Low priority) 04:36 anomalies.** Empty `last-crash.log` at launch time; `api-port` rewritten at 10:00 by a process started at 04:36. Likely benign but unexplained.

## Addendum (same day): diarization backfilled

Ran SpeakerKit diarization on the system-audio WAV via `VoiceprintAudit --raw` (with `CAP_SECONDS` temporarily raised 1500 → 4000 to cover the 53.5-min session; reverted after). Result: 2 far-side clusters — Speaker 2 (brief, ~14s/26 segs, greets "Mr. Dan" at meeting start) and Speaker 3 (dominant, ~21.5 min/783 segs). The recovered transcript's `**Them**` lines were relabeled by time-overlap against cluster segments (You 204 / Speaker 2 13 / Speaker 3 215) and a schema-1 `VoiceprintSidecar`-compatible `*.voiceprints.json` (source `system`, `includesYou: false`, session GUID set) was written next to the transcript. Segment re-transcription was NOT run — text remains the live ASR output; noted in the transcript's `recovery_note`. **The WAV buffers in `~/Library/Application Support/Tome/sessions/` are now safe to delete** (kept pending user confirmation).

## Reference: rebuild script used for the transcript

The scratchpad copy is session-temporary; preserved here for reuse. Usage: `python3 rebuild_transcript.py <session.jsonl> <out.md>` (session start time, duration, filenames, and GUID are hardcoded for this session — parameterize if turning this into tooling).

```python
#!/usr/bin/env python3
"""Rebuild a Tome transcript markdown from a session JSONL crash-recovery file."""
import json, sys
from datetime import datetime, timezone

jsonl_path = sys.argv[1]
out_path = sys.argv[2]

start = datetime(2026, 7, 23, 14, 1, 10, tzinfo=timezone.utc)  # session startedAt (UTC)

entries = []
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        ts = datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00"))
        entries.append((ts, e["speaker"], e["text"]))

entries.sort(key=lambda x: x[0])
dur_s = 3211  # from afinfo of the session WAV
duration = f"{dur_s // 60}:{dur_s % 60:02d}"
label = {"you": "You", "them": "Them"}

body = []
for ts, spk, text in entries:
    off = (ts - start).total_seconds()
    body.append(f"**{label.get(spk, spk)}** ({off:.3f})\n{text}\n")
# ... frontmatter block with type/created/time/duration/source_file/recording/
# session_guid/tags + recovered: true, then "## Transcript" and the body.
```

Audio mix (throwaway Swift, deprecation warnings harmless): build an `AVMutableComposition`, `addMutableTrack(.audio)` per WAV, `insertTimeRange` from each `AVURLAsset`, export with `AVAssetExportSession(presetName: AVAssetExportPresetAppleM4A)` to `.m4a`.

## Addendum (2026-07-23, patch session): fixes implemented; "logging blackout" was a query error

### The logging blackout never existed (§3 retracted)

The investigation's `log show` queries failed for two compounding reasons:

1. **Wrong subsystem.** The code logs under `com.dloomis.tome` (see `tomeLogSubsystem` in `TranscriptionEngine.swift`); the queries (and a stale line in CLAUDE.md, now corrected) used `io.gremble.tome`.
2. **zsh `log` builtin.** In zsh, `log` is a shell builtin — `log show …` runs the builtin, which errors "too many arguments"; with stderr discarded/piped, that reads as zero entries. This also explains the `process == "Tome"` query returning nothing. Use `/usr/bin/log` explicitly.

With `/usr/bin/log show --predicate 'subsystem == "com.dloomis.tome"'`, the entire session is present in the log store — capture start, per-buffer diagnostics, and the exact failure:

```
10:54:42  [JOB session_2026-07-23_10-01-10] starting run, … sessionType=callCapture
10:54:54  [DIARIZE] Found 809 segments, 2 speakers, 2 centroids
10:55:15  [RETRANSCRIBE] Produced 180 segments from 187 merged diarization segments
10:55:15  [FINALIZER] rebuildFromDiarizedSegments: transcript unreadable at …/SDA/Transcripts/2026-07-23 10-01-10 Call Recording.md: … NSPOSIXErrorDomain Code=2 "No such file or directory"
10:55:15  [JOB session_2026-07-23_10-01-10] durable write failed: markdownReadFailed(…) — WAV preserved at …
10:55:15  [QUEUE] Job session_2026-07-23_10-01-10 failed: markdownReadFailed(…)
```

This **confirms the inferred failure chain end to end**: diarization and re-transcription both succeeded; only the markdown rebuild failed on the unlinked note, aborting the job with the WAVs preserved. (Also visible: `[APIServer] Listening on http://127.0.0.1:27080` at 10:00:52 — the API server re-bound then, explaining the `api-port` mtime from §"Timeline"; the 04:36 empty `last-crash.log` remains unexplained but benign.)

The File ▸ Logs menu was never affected (it already invokes `/usr/bin/log` with the correct subsystem).

### Fixes implemented (all with regression tests, `swift test` green)

1. **Self-heal on transcript disappearance** (plan item 1) — `TranscriptLogger` now keeps the session's full utterance history in memory (`fullHistory`); every flush (i.e. every `append`) and the 10s `flushIfNeeded` timer check the note still exists. If it was deleted externally, the logger closes the orphaned handle and recreates the note at the same path — frontmatter, applied context, and complete history — then keeps recording as an unlinked meeting. A missing *folder* (vault unmount) is deliberately not healed: `lastError` surfaces the banner as before, and every subsequent flush retries, so a remount heals automatically. Header/body rendering was factored into `TranscriptLogger.documentHeader`/`renderUtterances` statics so recreated notes are byte-compatible with live ones.
2. **Finalize fallback from JSONL** (item 2) — new `TranscriptRebuilder` (Storage/) rebuilds a live-format note from the session JSONL. `PostProcessingJob.run` invokes it when the note is missing and `relocateRenamedNote` finds nothing, so diarization → rebuild → finalize → retention proceed normally. Refuses to clobber an existing file; tolerates a crash-truncated JSONL tail.
3. **Failure surfacing** (item 3) — the queue already posted a failure notification (added post-1.5.1); now a failed job also writes a machine-readable `<sessionId>.failed.json` marker (schema, guid, error, paths — `JobFailureMarker` in Recovery/) next to the JSONL. Cleared on a later verified success of the same session id and by `OrphanScanner.discard`.
4. *(No WhisperCal changes — as specified.)*
5. **Logging** (item 5) — no persistence defect to fix (see above). Added `diagLogError(_:)` (`.error` level) and moved transcript-disappearance, flush/finalize write failures, and job failures onto it. CLAUDE.md subsystem string corrected; `/usr/bin/log` gotcha documented.
6. **JSONL-first orphan recovery** (item 6) — the launch-time orphan flow (`ContentView.recoverOrphans`) now rebuilds a missing transcript from the session JSONL (via sidecar metadata) after relocation fails, instead of reporting "transcript file missing", so WAV-only orphans of this incident's shape recover end to end.
7. **04:36 anomalies** (item 7) — left open; the log store shows nothing abnormal at 04:36 beyond the breadcrumb-handler install line.

### Follow-ups

- The two 616 MB WAV buffers for this session are still in `~/Library/Application Support/Tome/sessions/` — diarization was backfilled, so they're safe to delete on user confirmation. Note the next launch's orphan scan will now offer them for recovery; choose **Discard All** (the transcript is already recovered) or delete the files first.
- These fixes ship in the next release; 1.5.1 in the field still has the original behavior.
