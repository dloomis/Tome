# Whisper Large v3 Turbo as a Selectable Transcription Model

**Date:** 2026-07-08
**Status:** Approved design, pending implementation
**Base branch:** `resilience-full` (feature branch: `whisper-v3-turbo-model-option`)

## Summary

Add OpenAI Whisper Large v3 Turbo (via WhisperKit, already in the dependency tree)
as a user-selectable transcription model alongside the existing Parakeet-TDT v3
(FluidAudio). The model is chosen from a drop-down in Settings ▸ Transcription,
downloads lazily when selected, and the main screen gates recording on model
readiness ("DOWNLOADING MODEL…" instead of the record buttons being usable).
A failed download auto-reverts to the last working model so recording is never
left disabled without a path back.

## Goals

- Model drop-down in Settings ▸ Transcription: Parakeet-TDT v3 (default) and
  Whisper Large v3 Turbo.
- Lazy download: selecting a model starts its download/load immediately, in the
  background; the previously loaded model keeps serving until the new one is ready.
- Main-screen record buttons disabled during download/load, with an explicit
  "DOWNLOADING MODEL… N%" status; no state can leave recording disabled with no
  recovery path.
- The selected model serves **both** live streaming transcription and
  post-processing re-transcription (they already share one choke point).
- Load-test data comparing Whisper v3 Turbo vs Parakeet for live-transcription
  responsiveness, gathered before the feature is called done.
- Unit tests for the full download/failure state machine, running in CI without
  real model downloads; the existing `resilience-full` test suite stays green.

## Non-Goals

- Per-task model split (e.g. Parakeet live + Whisper post-processing). One
  setting drives both. The protocol design leaves room for this later.
- Language/locale picker work (Settings shows locale read-only today; unchanged).
- Supporting more than these two models now.
- Removing or migrating existing FluidAudio behavior — Parakeet's code path is
  extracted, not rewritten.

## Decisions Already Made (with Nic)

| Decision | Choice |
|---|---|
| Base branch | `resilience-full` (has the 14-file test suite + CI workflow; `main` is its ancestor) |
| Download failure | Auto-revert selection to last working model; error surfaced with Retry in Settings; recording re-enabled immediately |
| Model change while recording | Picker is **disabled** during an active session ("Stop recording to change models") |
| Architecture | Backend protocol behind `ASRCoordinator` (approach A) |

## Current Architecture (facts the design builds on)

- `ASRCoordinator` ([ASRCoordinator.swift](../../../Tome/Sources/Tome/Transcription/ASRCoordinator.swift))
  is an actor and the single point all transcription flows through: live
  (`StreamingTranscriber`) and batch (`SegmentReTranscriber`). It is hardcoded to
  FluidAudio: `AsrModels.downloadAndLoad(version: .v3)` + `AsrManager`, with a
  fresh `TdtDecoderState` per call (deliberate — see the file's header comment).
- Model loading happens **inside `TranscriptionEngine.start()`** today (lazy on
  first record), reporting progress via static `assetStatus` strings
  ("Loading ASR model (~600MB first run)...").
- WhisperKit is already a linked product of the pinned `argmax-oss-swift`
  package (used today for diarization via SpeakerKit, and imported by
  `TranscriptionEngine`).
- `AppSettings` is `@Observable @MainActor`; every property persists via
  `didSet` → `UserDefaults` — settings apply on change, there is no separate
  Save action.
- `ControlBar` renders two record buttons (Call Capture ⌘R, Voice Memo ⌘⇧R) when
  not recording; it already displays `statusMessage` (from
  `TranscriptionEngine.assetStatus`) and `errorMessage` (from `lastError`) lines.
- Tests: `TomeTests` target on this branch runs via `swift test` (needs
  `DEVELOPER_DIR` pointing at full Xcode). Tests deliberately touch no audio
  devices or ASR models.

## Design

### 1. Model identity and persistence

```swift
enum TranscriberModel: String, CaseIterable, Sendable, Codable {
    case parakeetTDTv3 = "parakeet-tdt-v3"      // default
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
}
```

- `AppSettings.transcriberModel: TranscriberModel`, persisted through the
  existing `didSet` → UserDefaults pattern (key `"transcriberModel"`; unknown
  raw values fall back to `.parakeetTDTv3`).
- The **last-good model** (most recent model that reached `ready`) is persisted
  separately (key `"lastGoodTranscriberModel"`) so revert-on-failure survives
  app restarts. Defaults to `.parakeetTDTv3`.

### 2. Backend protocol

```swift
protocol ASRBackend: Sendable {
    var model: TranscriberModel { get }
    /// True if the model's files are already on disk (no network needed to load).
    static func isInstalled() -> Bool
    /// Download (if needed) and load into memory. Progress ∈ [0,1] covers the
    /// download phase; the load phase reports as indeterminate.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws
    func transcribe(samples: [Float], language: Language) async throws -> ASRResult
    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult
    /// Release model memory. Called after a successful swap to the other backend.
    func unload() async
}
```

- **`ParakeetBackend`** — extraction of today's `ASRCoordinator` internals:
  `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager`, fresh
  `TdtDecoderState` per call. Behavior byte-for-byte equivalent to today.
- **`WhisperBackend`** — WhisperKit, loading the large-v3-turbo model
  (WhisperKit model naming like `openai_whisper-large-v3-v20240930_turbo`;
  exact identifier in the pinned argmax-oss-swift revision **verified at
  implementation time**, including its download-progress callback API).
  Whisper returns text per audio chunk like Parakeet does; the existing
  VAD-chunked pipeline calls it identically. `Language` maps to Whisper's
  ISO-639-1 language option.
- Both return `ASRResult` (FluidAudio's type, already the pipeline currency).
  WhisperBackend adapts WhisperKit's result into `ASRResult`. If `ASRResult`
  proves unconstructable outside FluidAudio, introduce a small
  `TranscriptionResult` struct at the coordinator boundary instead — the
  decision is the implementer's; call sites only use `.text` (and confidence
  where available).

### 3. ASRCoordinator changes

The actor keeps its role and public surface (`transcribe(samples:source:)`,
`transcribe(buffer:source:)`, `setLanguage`) so `StreamingTranscriber` and
`SegmentReTranscriber` need **zero changes**. Internally:

- `private var activeBackend: (any ASRBackend)?` — the backend serving
  transcribe calls. Replaced only on successful swap; `transcribe` throws
  `.notInitialized` when nil (same as today).
- `func install(backend: any ASRBackend)` — atomic swap between transcribe
  calls (actor serialization gives this for free), then `unload()` on the old
  backend. Steady state: **one model resident in memory**.
- `initialize()` is superseded by the provisioning flow below but retained as
  "ensure the currently selected backend is ready" for `TranscriptionEngine.start()`.

### 4. Provisioning and the model state machine

New `@Observable @MainActor final class ModelProvisioner` (Transcription/),
owned by `AppServices` alongside the coordinator. It is the **only** writer of
model state and the only component that starts downloads.

```
                    select model M (Settings didSet / launch / Retry)
                                     │
        ┌────────────────────────────▼───────────────────────────┐
        │ cancel any in-flight provisioning task for another model│
        └────────────────────────────┬───────────────────────────┘
                                     ▼
  ready(M) already? ──yes──▶ done (no-op)
        │no
        ▼
  downloading(M, progress) ──▶ loading(M) ──▶ ready(M)
        │                          │             │
        │ error/cancel             │ error       ├─ persist M as last-good
        ▼                          ▼             └─ coordinator.install(backend)
      failed(M, error) ────────────┘
        │
        ├─ revert AppSettings.transcriberModel to last-good (no re-download:
        │  its backend is still installed and serving)
        └─ recording availability returns to the last-good model's state
```

`ModelProvisioner.state: ModelState` where

```swift
enum ModelState: Equatable {
    case idle                                   // nothing provisioned yet (pre-launch-kick)
    case downloading(TranscriberModel, progress: Double?)  // nil = indeterminate
    case loading(TranscriberModel)
    case ready(TranscriberModel)
    case failed(TranscriberModel, message: String)
}
```

Rules, exhaustively:

1. **Selection change** (Settings `didSet`): provisioner cancels any in-flight
   task, then provisions the new selection. The previously **ready** backend
   stays installed in the coordinator and keeps serving until the new backend
   is ready — recording stays available on the old model during the download.
2. **Success**: backend installed in coordinator, old backend unloaded,
   selection persisted as last-good, state → `ready(new)`.
3. **Failure** (network down, HuggingFace unavailable, disk full, corrupt
   download, load error): state → `failed(M, message)`. Provisioner reverts
   `AppSettings.transcriberModel` to last-good **without triggering a new
   provisioning cycle** (guarded write — the revert must not recurse through
   `didSet`). The coordinator still holds the last-good backend, so recording
   is immediately available again. The failure message surfaces in Settings
   (inline, with Retry) and on the main screen (transient via existing
   `lastError` plumbing).
4. **First-run failure edge**: if no model has ever reached ready (fresh
   install, offline), there is no last-good backend. Selection stays put,
   state stays `failed`, record buttons stay disabled and show the failed
   status with Retry available in Settings. (Nothing could transcribe anyway;
   this is the only state where recording remains blocked, and it has an
   explicit retry path.)
5. **Cancel mid-download** (user re-selects the other model): in-flight task
   cancelled cooperatively; no `failed` state emitted for cancellation;
   provisioning proceeds for the new selection.
6. **Launch**: provisioner kicks off provisioning of `settings.transcriberModel`
   at app startup (from `TomeApp`/`AppServices` init), so READY is truthful
   before first record. Cached-on-disk models load without network
   (`isInstalled()` short-circuits the download phase; loading from disk
   offline must succeed).
7. **App killed / crashes mid-download**: partial downloads are the SDKs'
   concern (both resume/redownload on next attempt); on relaunch the state
   machine simply provisions the selected model again from `idle`.
8. **Cache deleted while selected** (user clears `~/.cache/fluidaudio` or the
   WhisperKit model folder between launches): `isInstalled()` is consulted at
   provision time only — a deleted cache is discovered at next launch/selection
   and triggers a re-download, not a crash.
9. **Recording active**: the Settings picker is disabled (decision above), so
   selection cannot change mid-session. `TranscriptionEngine.start()` is only
   reachable when state is `ready` (UI gating), but start() still defensively
   awaits coordinator readiness as today.

### 5. TranscriptionEngine.start() interaction

Today start() loads the ASR model inline. After this change:

- The ASR model is provisioned by `ModelProvisioner` (eagerly at launch and on
  selection change). `start()` calls `asrCoordinator.initialize()` as a
  defensive "await ready" (no-op when the backend is installed), and the VAD
  model load stays in `start()` unchanged.
- The hardcoded status strings become model-aware:
  `"Loading ASR model (~600MB first run)..."` → derived from the selected
  model's display name and approximate size;
  `"Transcribing (Parakeet-TDT v3)"` → `"Transcribing (\(model.displayName))"`.

### 6. Settings UX (Settings ▸ Transcription)

New "Model" section **above** the existing read-only Language section:

- `Picker("Model", …)` with two rows:
  - **Parakeet-TDT v3** — "fast, streaming-optimized (default)"
  - **Whisper Large v3 Turbo** — "higher accuracy, larger download"
- A status line under the picker mirroring `ModelState` for the *selected* model:
  - `ready` → "Downloaded ✓"
  - not installed, not selected-provisioning → "Not downloaded (~1.5 GB)"
  - `downloading` → "Downloading… 42%" (indeterminate → "Downloading…")
  - `loading` → "Loading model…"
  - `failed` → the error message + **Retry** button (re-runs provisioning for
    the failed model; selecting it in the picker again does the same).
- While recording (`isRecording`): picker `.disabled(true)` with caption
  "Stop recording to change models."
- Sizes shown are approximate and hardcoded per model (Parakeet ~600 MB,
  Whisper v3 Turbo ~1.5 GB; confirm Whisper's real size during implementation
  and update the copy).

### 7. Main screen UX (ControlBar)

- Both record buttons are **disabled** (greyed, `.disabled`) unless
  `ModelState == .ready`. Keyboard shortcuts and any menu-bar/API start paths
  gate on the same check (single source of truth: a computed
  `canStartRecording` on the observable state).
- Status label while provisioning (replaces the record buttons' usable state,
  reuses the existing `statusMessage` row):
  - `downloading` → **"DOWNLOADING MODEL… 42%"**
  - `loading` → **"LOADING MODEL…"**
  - `failed` with revert → transient error line (existing `errorMessage` row):
    "Whisper download failed — reverted to Parakeet-TDT v3: <reason>"
  - `failed` first-run (no last-good) → persistent "MODEL DOWNLOAD FAILED —
    retry in Settings ▸ Transcription", buttons stay disabled.
- The API server's start-recording endpoint returns an error ("model not
  ready") instead of silently failing when provisioning is in flight.

### 8. Load testing: Whisper v3 Turbo vs Parakeet for live use

New CLI target **`ASRBench`** (pattern: existing `VoiceprintAudit` CLI target).
Run manually on Nic's machine — **not** in CI (CI can't download models or
guarantee ANE availability).

- Input: one or more 16 kHz mono WAV fixtures (a real recording; the CLI also
  accepts any WAV and resamples like `StreamingTranscriber` does).
- Method: replays the audio through both backends with the same chunking the
  live pipeline produces (VAD-bounded segments, up to the ~30 s flush window),
  measuring per chunk.
- Report, per backend:
  - model download size on disk & model load time (cold and warm)
  - first-transcription latency (ANE warm-up — known Whisper cost)
  - per-chunk latency p50 / p95, and real-time factor (RTF)
  - peak resident memory
- **Acceptance bar for live use: p95 chunk latency comfortably under chunk
  duration — RTF < ~0.5.** If Whisper misses the bar, the feature still ships;
  the drop-down copy gains "may lag during live transcription" and the numbers
  go in the PR description for a follow-up decision.

### 9. Testing strategy

**Unit tests (CI, no real models):** a `FakeBackend` conforming to
`ASRBackend` with scriptable prepare behavior (succeed after N progress ticks,
fail with error E, hang until cancelled). Provisioner + coordinator tests:

1. select → downloading → ready; coordinator swaps; old backend unloaded.
2. download failure → `failed`, selection reverted to last-good, revert does
   **not** trigger re-provisioning (no recursion), coordinator still serves.
3. failure with no last-good (first run) → stays failed, retry works.
4. cancel mid-download by re-selecting → no failed state, new model provisions.
5. selecting the already-ready model → no-op.
6. `transcribe` during swap: calls before `install` use the old backend, after
   use the new — never `.notInitialized` while a ready backend exists.
7. last-good persistence round-trips through UserDefaults (restart scenario).
8. unknown persisted raw value falls back to Parakeet.

**Existing suite:** all `TomeTests` from `resilience-full` stay green
(`swift test`, `DEVELOPER_DIR` pointing at full Xcode).

**Smoke tests (manual, on-device):** for **each** model: record a short call
capture and a voice memo → live transcript appears → stop → post-processing
completes → final transcript written. Plus: flip models mid-idle, kill network
and select the un-downloaded model (observe revert), retry from Settings.

**State-audit agent pass (final gate):** an agent enumerates the matrix —
{selected model} × {cached / not cached} × {network up / down} × {recording
active / idle} × {app relaunched mid-download} × {cache deleted while
selected} × {first run / has last-good} — and traces each cell through the
implemented code, hunting specifically for: recording disabled with no
recovery path, `failed` states with no retry affordance, provisioning
recursion via the revert write, and stale UI (button says downloading, nothing
in flight). Findings are fixed before the branch is called done.

## Risks & open items

- **WhisperKit model identifier & progress API** in the pinned
  argmax-oss-swift revision must be confirmed at implementation start (the pin
  predates some upstream renames). If the pinned revision can't load
  large-v3-turbo, options are re-pinning (coordinate with upstream freeze —
  see repo collaboration notes) or a different Whisper variant; surface before
  building further.
- **Whisper live latency is unknown** until ASRBench runs — the design
  deliberately ships the drop-down regardless and lets the numbers drive copy.
- **Memory**: two models are briefly co-resident during a swap (old serving,
  new loading). Whisper v3 Turbo + Parakeet simultaneously is the peak;
  acceptable transiently on Apple Silicon, and steady state is one model.
- **`ASRResult` constructability** outside FluidAudio (see §2 fallback).
- Upstream (`dloomis/Tome`) API surface is frozen pending discussion — the
  local HTTP API gains only an error response, no new endpoints.

## Out of scope

Per-source model selection, model auto-selection heuristics, download pause /
resume UI, deleting downloaded models from Settings, locale picker.
