<h1 align="center">Tome</h1>

<p align="center">
  <strong>Local meeting capture → Obsidian vault → AI agent pipeline. No cloud. No API keys. Your data.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2" />
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-Required-333333?logo=apple&logoColor=white" alt="Apple Silicon" />
</p>

---

> **Fork note:** Tome was created at [Gremble-io/Tome](https://github.com/Gremble-io/Tome) — the original idea and first release belong to the upstream author. Upstream has since evolved into a different product ([Detto](https://github.com/Gremble-io/Tome), a dictation-first app under a BSL license), so **this fork is where Tome continues**. It has diverged substantially from the last upstream release: post-session speaker diarization, a local HTTP API for agent integration, crash-safe capture with one-click recovery, opt-in audio retention with click-to-play timestamps, and more — see [Fork Additions](#fork-additions). It stays MIT-licensed, and new work lands against a public [roadmap](ROADMAP.md). If you're deciding which version to install or build on, this is the actively maintained one.

Tome is a macOS app that captures meetings and voice memos, transcribes them locally with Parakeet-TDT v3 (via FluidAudio), and drops structured `.md` files straight into your Obsidian vault. Everything runs on-device. Nothing phones home.

<p align="center">
  <img src="assets/screenshot-idle.png" width="350" alt="Tome — idle state" />
  <img src="assets/screenshot-recording.png" width="350" alt="Tome — recording with spectrum visualizer" />
</p>

## Background

Tome exists for one workflow: capture → vault → agent. If you're on calls all day and don't take notes, you want something that listens, transcribes, and drops structured markdown into your Obsidian vault where an agent layer can do the rest — pull action items, update client files, connect the dots. Otter, Granola, and Fireflies all lock your data in their cloud, none of them output plain markdown, and none of them are built to feed an agent pipeline.

The original Tome nailed that idea, and full credit goes to its author. I forked it to push the workflow further — speaker diarization, crash-safe capture, a local API so other tools can drive it — and since upstream has evolved into [Detto](https://github.com/Gremble-io/Tome), a dictation-first app, this fork is where Tome development continues. The [Fork Additions](#fork-additions) below show how far it's come; the [roadmap](ROADMAP.md) shows where it's headed.

## Why Tome?

- **Plain markdown out.** YAML frontmatter, tags, timestamps. Your vault already knows what to do with it. No proprietary export, no copy-paste, no middleman.
- **Built for the agent pipeline.** Tome is just the capture layer. You talk, it transcribes, your agent picks up the `.md` and does whatever you've wired it to do.
- **Runs on your machine.** Parakeet-TDT v3 on Apple Silicon. No API keys, no accounts, no subscriptions, no data leaving the building.

```
speak → capture → vault → agent → knowledge base
```

Tome does the first three. Your agent does the rest.

## Features

- **Local transcription** via Parakeet-TDT v3 ([FluidAudio](https://github.com/FluidInference/FluidAudio)) on Apple Silicon. Nothing hits the network.
- **Call Capture** grabs mic + system audio. Detects which conferencing app you're in (Teams, Zoom, Slack, etc.) and filters audio to just that app. Your Spotify and notification sounds stay out of the transcript.
- **Voice Memo** is mic only. For quick thoughts, verbal notes, stream of consciousness. Saves to a separate folder so it doesn't clutter your meeting transcripts.
- **Speaker diarization** runs after the call ends. pyannote splits the remote audio into Speaker 2, Speaker 3, Speaker 4. Not perfect, but way better than one wall of unattributed text.
- **Vault-native output** writes `.md` with frontmatter: `type`, `created`, `attendees`, `tags`, `source_app`. Lands in your vault ready to process.
- **Privacy.** Hidden from screen sharing by default. Audio is discarded after transcription — opt in to recording retention if you want to keep the audio file.
- **Timestamped lines.** Every transcript line is tagged with its start offset in seconds from the start of the recording (e.g. `(3.120)`). Drops straight into an [Obsidian Media Extended](https://github.com/aidenlx/media-extended) `#t=` link, so a line can replay the exact moment of audio it came from.
- **Optional recording retention.** Off by default. When enabled (Settings > Output), each session's combined audio — your mic plus the other side — is exported as a single `.m4a` (~25 MB/hour) to a folder you choose. Leave it off and nothing but text is kept.
- **Silence detection that asks first.** After a configurable stretch of dead air (default 120s, slider in Settings, 0 disables), Tome prompts you — in-app and via a notification with Stop/Keep buttons — instead of cutting the recording. Nothing stops without your confirmation, and the prompt dismisses itself if audio resumes.
- **Menu bar status.** The menu bar book icon fills red and pulses while a session is recording, and pulses monochrome while a finished session is still being diarized in the background.
- **Configurable filenames.** Settings > Output exposes the date format and per-session-type labels so files land as `2026-05-20 14-30-00 Call Recording.md` or whatever pattern you prefer.
- **Crash-safe recordings.** WAVs are written with a self-healing header and stored under `~/Library/Application Support/Tome/sessions/` — a crash mid-meeting leaves a readable file. On next launch, Tome detects orphaned sessions and offers one-click recovery (diarization + transcript rebuild) or a manual `File > Recover from WAV…` (Cmd+Opt+R) for legacy WAVs.

## How It Works

```
┌─────────────┐     ┌──────────────────┐     ┌───────────────┐
│  Microphone  │────▶│                  │     │               │
└─────────────┘     │  Tome            │     │  Obsidian     │
                    │  ┌────────────┐  │────▶│  Vault        │
┌─────────────┐     │  │ Parakeet   │  │     │  (.md files)  │
│  System      │────▶│  │ TDT v3    │  │     │               │
│  Audio       │     │  └────────────┘  │     └───────┬───────┘
└─────────────┘     └──────────────────┘             │
                                                     ▼
                                              ┌──────────────┐
                                              │  AI Agent    │
                                              │  Layer       │
                                              │  (notes,     │
                                              │   actions,   │
                                              │   updates)   │
                                              └──────────────┘
```

1. **Capture** picks up mic audio + system audio from a specific conferencing app via ScreenCaptureKit.
2. **Transcribe** runs VAD to detect speech segments, then Parakeet transcribes locally.
3. **Diarize** splits the system audio into individual speakers after the session ends.
4. **Write** drops structured `.md` with YAML frontmatter into your vault folder.
5. **Agent picks up** whatever you've got downstream processes the transcript.

## Output

<p align="center">
  <img src="assets/screenshot-vault-frontmatter.png" width="600" alt="Vault note with YAML frontmatter" />
</p>

<p align="center">
  <img src="assets/screenshot-vault-transcript.png" width="600" alt="Vault note transcript view" />
</p>

```markdown
---
type: meeting
created: "2026-03-23"
time: "10:00"
duration: "18:42"
source_app: "Zoom"
recording: "[[2026-03-23 Call Recording.m4a]]"
attendees: ["You", "Speaker 2"]
tags:
  - log/meeting
  - status/inbox
  - source/tome
---

# Call Recording — 2026-03-23 10:00

**You** (3.120)
Morning. Quick sync on the product launch. Where are we at?

**Speaker 2** (7.480)
We're in good shape. QA signed off yesterday, marketing assets
are locked, landing page is live in staging.
```

Voice memos use `type: fleeting` with a single speaker. Same structure, same frontmatter.

Each line is tagged with its start offset in seconds (millisecond precision) from the
beginning of the recording. The value drops straight into an [Obsidian Media Extended](https://github.com/aidenlx/media-extended)
`#t=` fragment — e.g. `[[recording.m4a#t=3.120]]` — so a transcript line can jump the
audio to the exact moment it was spoken.

The `recording:` frontmatter property is written only when recording retention is on. It's
an Obsidian wikilink (quoted so the `[[…]]` parses as a YAML scalar) to the session's
`.m4a`, so Obsidian cleanly links the transcript and its audio.

## Build

**Requirements:** Apple Silicon Mac, macOS 26+, Xcode 26.3+

```bash
git clone https://github.com/dloomis/Tome.git
cd Tome
./scripts/build_swift_app.sh
```

Builds and installs to `/Applications`. First launch downloads the Parakeet ASR model (~600MB, cached after that).

**Dev build:**

```bash
cd Tome
swift build
```

## Permissions

| Permission | When | Why |
|---|---|---|
| **Microphone** | All modes | Captures your voice |
| **Screen Recording** | Call Capture only | ScreenCaptureKit needs this for system audio from conferencing apps |

macOS re-prompts for Screen Recording permission roughly monthly. That's an OS thing, not Tome.

## Architecture

```
Tome/Sources/Tome/
├── App/
│   ├── TomeApp.swift               # App entry point
│   └── AppUpdaterController.swift  # Sparkle update controller
├── Audio/
│   ├── SystemAudioCapture.swift    # ScreenCaptureKit + per-app filtering
│   └── MicCapture.swift            # AVAudioEngine mic input
├── Models/
│   ├── Models.swift                # Domain types (Utterance, Speaker, etc.)
│   └── TranscriptStore.swift       # Observable transcript state
├── Transcription/
│   ├── TranscriptionEngine.swift   # Dual-stream capture + diarization
│   ├── StreamingTranscriber.swift  # VAD + Parakeet ASR pipeline
│   └── SegmentReTranscriber.swift  # Per-speaker re-transcription after diarization
├── API/
│   ├── APIServer.swift             # Local HTTP server for WhisperCal integration
│   └── APIModels.swift             # Request/response types and OpenAPI spec
├── Storage/
│   ├── TranscriptLogger.swift      # .md output with YAML frontmatter
│   └── SessionStore.swift          # Session metadata
├── Recovery/
│   ├── Recovery.swift              # Manual + automatic orphan recovery pipeline
│   ├── WAVStreamWriter.swift       # Crash-resilient WAV writer (self-healing header)
│   ├── SessionSidecar.swift        # Per-session {sessionId}.session.json metadata
│   └── OrphanScanner.swift         # Launch-time scan + recovery prompt
├── Settings/
│   └── AppSettings.swift
└── Views/
    ├── ContentView.swift
    ├── ControlBar.swift
    ├── TranscriptView.swift
    ├── SettingsView.swift
    ├── OnboardingView.swift
    └── CheckForUpdatesView.swift
```

## Privacy

- Transcription runs entirely on-device. No audio is ever sent anywhere.
- No network calls. No analytics. No telemetry.
- Audio is not saved by default — only text transcripts. Optional recording retention (off by default, Settings > Output) keeps a combined `.m4a` in a folder you choose; otherwise the working audio is deleted once post-processing finishes.
- The app window is hidden from screen sharing by default.
- Transcripts are saved as plain `.md` files to a folder you choose.

## Known Limitations

- **Apple Silicon only.** Parakeet and FluidAudio need Metal / ANE. No Intel.
- **macOS 26+ only.**
- **Screen Recording re-prompts monthly.** OS limitation.
- **Diarization is imperfect.** Works well with headset mics. Laptop speakers with crosstalk will give you worse speaker separation.
- **No live speaker labels.** Diarization runs after the session ends. During the call, remote audio shows as a single stream.

## Fork Additions

This fork has diverged substantially from the original project — and since upstream's pivot to Detto, it's where Tome development happens. Relative to the last upstream release of Tome, this fork adds:

### Diarization & transcription

- **SpeakerKit diarization (pyannote v4)** — replaces upstream's FluidAudio offline diarizer with [SpeakerKit](https://github.com/argmaxinc/WhisperKit). After a session ends, system audio is re-processed for speaker segmentation and each segment is re-transcribed with per-speaker labels.
- **Background post-session processing** — diarization + frontmatter finalization run on a serial background queue (`PostProcessingQueue`) so a new recording can start immediately after Stop. The menu bar icon pulses while finalization is in flight.
- **Keep transcribing while the display sleeps** — capture and ASR are no longer interrupted by display sleep.
- **Dynamic ASR language hint** — `AppSettings.transcriptionLanguage` flows through to the ASR coordinator at session start and on the fly; UI exposure ships in the next release.
- **Fresh TDT decoder state per transcribe call** — eliminates cross-utterance state bleed that produced empty/duplicated outputs on FluidAudio 0.14.

### Reliability & durability

- **fsync on every disk write** — `TranscriptLogger` and `SessionStore` call `fileHandle.synchronize()` after every flush so the last 1–3 utterances survive kernel panic, SIGKILL, or sudden power loss (not just a process crash).
- **Terminate flush** — `applicationShouldTerminate` flushes both the live markdown writer and the JSONL crash-recovery file before the OS reaps the process, with a 2s hard cap.
- **Filename collision handling** — `TranscriptFinalizer` appends `-1`, `-2`, … instead of clobbering an existing file when context-based renames collide; the save banner reflects the resolved name.
- **Visible failures instead of silent drops** — mic device-set OSStatus errors, system-audio WAV write errors (counted through to the post-processing job as a warning), short-segment drops, vault-disappeared state, and context-update reopen failures all surface to a `lastError` polled by the UI.
- **Strict utterance ordering** — markdown and JSONL writes flow through a single-consumer `AsyncStream` instead of racing per-utterance Tasks.
- **YAML-safe context** — frontmatter `context:` is fully escaped (newlines, tabs, quotes) so multi-line context strings can't break parsers.
- **`[transcription failed]` placeholders** — re-transcription errors leave a visible hole in the final transcript instead of silently dropping the segment.
- **Crash-resilient WAV writer** — `WAVStreamWriter` replaces `AVAudioFile` for system-audio capture. The RIFF + `data` chunk sizes are refreshed in place after every buffer write, with `synchronize()` throttled to ~1 Hz on the SCStream callback queue. A crash, force-quit, or power loss leaves a readable WAV up to ~1 second before the failure, instead of a 0-byte-data header (the previous failure mode silently zeroed out hours of audio on disk).
- **Stable WAV storage** — system-audio WAVs live in `~/Library/Application Support/Tome/sessions/{sessionId}.wav` alongside the JSONL crash files. Out of `$TMPDIR`'s purge path. The success path of `PostProcessingJob` deletes the WAV, so anything left in `sessions/` is by definition an orphan.
- **Per-session sidecar** — `SessionSidecar` writes `{sessionId}.session.json` next to each WAV at capture start, carrying `sessionId`, `transcriptPath`, `startedAt`, `sourceApp`, `sessionType`, and audio format. Orphan recovery becomes deterministic (the WAV unambiguously knows which transcript it belongs to) rather than heuristic time-matching.
- **Launch-time orphan recovery** — on app boot, `OrphanScanner` enumerates `sessions/*.wav` and pairs each with its sidecar. If any are found, a consolidated alert surfaces with Recover All / Discard All / Decide Later. "Recover All" iterates through the diarization → re-transcription → body-rebuild pipeline and shows a summary; failures stay on disk for retry via the manual command.
- **Manual recovery command** — `File > Recover from WAV…` (Cmd+Opt+R) pairs an arbitrary WAV and transcript through two open panels. Useful for legacy WAVs without a sidecar (e.g. `$TMPDIR` files from before the resilience work).

### API & integration

- **Local HTTP API server** — `APIServer` on `127.0.0.1` for programmatic session control. Endpoints for starting/stopping recordings, polling session lifecycle, and retrieving transcripts. Accepts an optional `suggestedFilename` and `MeetingContext` so callers can control output naming and seed the `## Context` body. Port is written to `~/Library/Application Support/Tome/api-port` on launch; an OpenAPI 3.1 spec is served at `GET /` for discoverability. State machine: `idle → recording → transcribing → complete → idle`. Used by [WhisperCal](https://github.com/dloomis/WhisperCal) but any local client can call it.
- **Settings > API tab** — shows the fixed port, a copy-to-clipboard button for the base URL, and the full endpoint reference.
- **API race fix** — duplicate session-start requests are rejected instead of being honored in parallel.

### UI & customization

- **Tabbed Settings window** — five panes (General · Audio · Transcription · Output · API) with SF Symbol icons replace the single scrolling Form. Per-tab state means device enumeration and the API port read only happen when you visit those tabs.
- **Silence stop confirmation** — silence never ends a session on its own. After the configurable timeout (Settings > Audio slider, 0–600s in 30s steps, 0 disables, default 120s), recording continues while Tome asks: a Stop & Save / Keep Recording prompt in the control bar plus an actionable notification with the same buttons for when the window is hidden behind the meeting app. The prompt auto-dismisses if audio resumes, and Keep Recording re-arms it after another full silence window.
- **Live recording state in the menu bar** — the book icon fills red and pulses for the duration of a session (with a "Recording…" line in the menu), taking priority over the monochrome pulse used for background finalization.
- **Configurable filename template** — Settings > Output exposes the `DateFormatter` pattern plus per-session-type labels ("Call Recording", "Voice Memo" by default). Rename to "Scheduled Meetings", "Quick Notes", etc., or leave a label blank for date-only filenames. A shared sanitizer scrubs filesystem-hostile characters (`/ \ : ? * < > | "`, control chars, leading dots) so user-entered formats are always safe to commit to disk. The chosen format is snapshotted at session start so a mid-recording settings change doesn't shift the prefix on an in-flight session's post-processing rename.
- **Optional recording retention** — `Settings > Output > Recordings` toggle (off by default) exports each session's combined audio as a single `.m4a`. `RecordingMixer` pads each track by `firstSample − sessionStart` so the mic and system streams align to the same timeline as the transcript, then `PostProcessingJob` writes the file to the chosen folder (default `~/Documents/Tome/Recordings`) after diarization. With retention off, the working WAVs are deleted once post-processing finishes.
- **Per-line time offsets** — transcript lines are tagged with their start offset in seconds (millisecond precision) from the session start instead of wall-clock time. `StreamingTranscriber` derives the offset from a 16 kHz audio sample clock, so each line marks where its speech *begins* rather than when ASR finalized it. The decimal-seconds value (e.g. `(3.120)`) drops directly into an [Obsidian Media Extended](https://github.com/aidenlx/media-extended) `#t=` fragment — `[[recording.m4a#t=3.120]]` — for click-to-play against the retained recording.
- **File > Save Transcript (Cmd+S)** — manually save the current transcript at any time during or after a session via `NSSavePanel`.
- **View > Logs** — opens `/tmp/tome.log` for quick diagnostic inspection.
- **Window scene (single instance)** — replaces `WindowGroup` so macOS 26 stops adding the "+" duplicate-instance pill to the toolbar.
- **Drop full-screen / tab-bar menu entries** — `NSWindow.allowsAutomaticWindowTabbing = false` and window opt-out of full-screen, so the View menu stays clean.

### Other

- **Atomic file writes** with `replaceItemAt` for the markdown rewrite paths (frontmatter, context updates, rebuild-from-diarization).
- **Empty-transcript guard** for short sessions that previously got stuck on "Identifying speakers…".
- **Code quality** — session ID mismatch fixes in API responses, dead-code removal, and assorted bug fixes.

## Credits

Tome was created by the [upstream author](https://github.com/Gremble-io/Tome), who started from [OpenGranola](https://github.com/yazinsai/OpenGranola) and substantially rewrote it. This fork builds on that foundation and continues it.

## License

[MIT](LICENSE)
