# Whisper Large v3 Turbo as a Selectable Transcription Model

**Date:** 2026-07-08 (revised same day after 4-lens adversarial spec review — 26 confirmed findings folded in)
**Status:** Approved design, pending implementation
**Base branch:** `resilience-full` (feature branch: `whisper-v3-turbo-model-option`)

## Summary

Add OpenAI Whisper Large v3 Turbo (via WhisperKit, already in the dependency tree)
as a user-selectable transcription model alongside the existing Parakeet-TDT v3
(FluidAudio). The model is chosen from a drop-down in Settings ▸ Transcription,
downloads lazily when selected, and the main screen gates recording on model
readiness ("DOWNLOADING MODEL…" instead of usable record buttons). A failed
download auto-reverts to the last working model so recording is never left
disabled without a path back.

## Goals

- Model drop-down in Settings ▸ Transcription: Parakeet-TDT v3 (default) and
  Whisper Large v3 Turbo.
- Lazy download: selecting a model starts its download/load immediately, in the
  background. The previously installed backend **stays loaded** — it continues
  serving any in-flight post-processing work and is the instant fallback on
  failure — but **new recordings are disallowed until the selected model is
  ready** (main screen shows "DOWNLOADING MODEL…").
- No state may leave recording disabled without a recovery path (the sole
  exception: a fresh install where no model has ever been usable — there,
  Retry is the recovery path).
- The selected model serves **both** live streaming transcription and
  post-processing re-transcription. Model swaps never land mid-job (see §4a).
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
| Base branch | `resilience-full` (has the test suite + CI workflow; `main` is its ancestor) |
| Download failure | Auto-revert selection to last working model; error surfaced with Retry in Settings; recording re-enabled immediately (via the still-installed backend) |
| Model change while recording | Picker **disabled** during an active session (extended in §4a to post-processing/recovery, same rationale) |
| Recording during a model download | **Disallowed** — buttons gated, "DOWNLOADING MODEL…" (Nic's original requirement; the old backend still serves post-processing) |
| Architecture | Backend protocol behind `ASRCoordinator` (approach A) |

## Current Architecture (facts the design builds on)

- `ASRCoordinator` ([ASRCoordinator.swift](../../../Tome/Sources/Tome/Transcription/ASRCoordinator.swift))
  is an actor and the single point all transcription flows through: live
  (`StreamingTranscriber`) and batch (`SegmentReTranscriber`). It is hardcoded to
  FluidAudio: `AsrModels.downloadAndLoad(version: .v3)` + `AsrManager`, with a
  fresh `TdtDecoderState` per call (deliberate — see the file's header comment).
- ASR model loading happens in **two** places today: inside
  `TranscriptionEngine.start()` (lazy on first record) and inside
  `Recovery.run()` (launch-time orphan recovery and File ▸ Recover from WAV
  both call `asrCoordinator.initialize()` directly — Recovery.swift:108).
- Progress is reported via static `assetStatus` strings, which the local API
  **string-matches**: `GET /health` derives `modelsReady` from them
  (APIServer.swift:328-331) and `handleSessionStatus` maps
  `contains("Loading")` → "loading" (APIServer.swift:508). There are **two**
  start endpoints: `POST /start` and `POST /sessions/start`.
- WhisperKit is already a linked product of the pinned `argmax-oss-swift`
  package (used today for diarization via SpeakerKit).
- `AppSettings` is `@Observable @MainActor`; every property persists via
  `didSet` → UserDefaults. Propagation to services goes through SwiftUI
  observation (e.g. `ContentView.onChange(of: settings.transcriptionLanguage)`
  → `asrCoordinator.setLanguage`, ContentView.swift:133) — `AppSettings` and
  `AppServices` are independent `@State` in `TomeApp` with no reference to each
  other today; new wiring is part of this design (§4).
- `ControlBar` renders two record buttons (Call Capture ⌘R, Voice Memo ⌘⇧R) when
  not recording; it already has `statusMessage` and `errorMessage` display rows.
- Model files on disk: FluidAudio ASR models live under
  `~/Library/Application Support/FluidAudio/Models/` (NOT `~/.cache/fluidaudio`,
  which is TTS-only). WhisperKit's default download location is
  `~/Documents/huggingface` — unacceptable for us; §2 mandates an explicit
  `downloadBase`.
- Tests: the `TomeTests` suite on this branch (13 test files + `TestSupport`)
  runs via `swift test` (needs `DEVELOPER_DIR` pointing at full Xcode). Tests
  deliberately touch no audio devices or ASR models.

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
- **Last-good model** — the most recent model that reached ready — is persisted
  under `"lastGoodTranscriberModel"` and is **optional: absent until some model
  first reaches ready**. (A default value would make "fresh install, nothing
  ever worked" indistinguishable from "Parakeet genuinely worked before".)

### 2. Backend protocol

```swift
enum PrepareEvent: Sendable {
    case downloading(progress: Double?)   // nil = indeterminate
    case loading
}

protocol ASRBackend: Sendable {
    var model: TranscriberModel { get }
    /// True if everything needed for an offline load is on disk.
    /// For Whisper this includes BOTH the model folder AND the cached
    /// tokenizer.json — WhisperKit fetches the tokenizer from a separate
    /// HF repo on load if it's missing, which would break offline loads.
    static func isInstalled() -> Bool
    /// Download (if needed) and load into memory. Emits phase transitions;
    /// when isInstalled(), emits .loading immediately (no download phase).
    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws
    func transcribe(samples: [Float], language: Language) async throws -> ASRResult
    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult
    /// Release model memory. The coordinator calls this only after the
    /// backend's last in-flight transcribe call has completed (§3).
    func unload() async
}
```

- **`ParakeetBackend`** — extraction of today's `ASRCoordinator` internals:
  `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager`, fresh
  `TdtDecoderState` per call. Behavior byte-for-byte equivalent to today.
  FluidAudio already provides the needed hooks: `AsrModels.modelsExist(at:)`
  for `isInstalled()` and `downloadAndLoad(progressHandler:)` for progress.
- **`WhisperBackend`** — WhisperKit. Model variant selection:
  - OpenAI's Large v3 Turbo is the **`openai_whisper-large-v3-v20240930*`
    family** in whisperkit-coreml. Beware: `_turbo`/`_NNNMB` suffixes are
    WhisperKit *compression* variants, and **`openai_whisper-large-v3_turbo`
    is NOT the turbo model** (it's large-v3 with WhisperKit compression —
    the name most resembling "large v3 turbo" is the wrong one).
  - The pinned revision's device-support matrix offers no full-precision
    v20240930 on M1-class Macs (their supported build is
    `openai_whisper-large-v3-v20240930_626MB`, ~0.6 GB); full precision
    (~1.5 GB) is supported/default on M2+. **Resolve the variant at runtime**
    via WhisperKit's model-support API, constrained to the v20240930 family;
    derive the size shown in Settings copy from the resolved variant.
  - Pass an **explicit `downloadBase`** under Tome's Application Support
    (parallel to FluidAudio's location) and point `tokenizerFolder` at the
    same root, so `isInstalled()` has one root to check and 1.5 GB of model
    files never land in `~/Documents` (WhisperKit's default, which would also
    trigger a TCC Documents prompt).
  - `Language` maps to Whisper's ISO-639-1 language option. The existing
    VAD-chunked pipeline calls Whisper identically to Parakeet.
- Both return FluidAudio's `ASRResult` — it is a public struct with a public
  memberwise init in the pinned FluidAudio (AsrTypes.swift), so WhisperBackend
  constructs it directly from WhisperKit's result. No wrapper type needed.

### 3. ASRCoordinator changes

The actor keeps its role and public transcribe surface so `StreamingTranscriber`
and `SegmentReTranscriber` need **zero changes**. Internally:

- `private var activeBackend: (any ASRBackend)?` — the backend serving
  transcribe calls; `transcribe` throws `.notInitialized` when nil (as today).
- `func install(backend: any ASRBackend)` swaps the reference. **Swift actors
  are reentrant — serialization does NOT make the swap atomic with respect to
  in-flight calls**: `transcribe` suspends at the backend `await`, and
  `install` can run at that suspension point. The reference swap itself is
  safe (an in-flight call holds its own reference), but `unload()` must not
  run under an executing transcription (both SDKs' unload paths actively
  release CoreML models on the live instance). Discipline: the coordinator
  counts in-flight transcribe calls per backend (increment before the backend
  await, decrement in `defer`) and defers the old backend's `unload()` until
  its count reaches zero. Steady state: **one model resident in memory**
  (transiently two during a swap: old serving, new loading). Installs are also
  **token-ordered**: `install` carries the provisioning cycle's monotonic
  generation token, and an install whose token is not strictly greater than the
  last applied one is refused (its incoming backend unloaded) — so a late
  install from a superseded cycle can never silently swap in the wrong backend.
- `initialize()` is **removed**. The coordinator never downloads or loads
  models; `ModelProvisioner` (§4) is the only component that does. Callers
  that needed it are repointed in §5.

### 4. Provisioning and the model state machine

New `@Observable @MainActor final class ModelProvisioner` (Transcription/),
owned by `AppServices`. It is the **only** writer of provisioning state and
the only component that starts downloads. Its observable surface:

```swift
enum ProvisioningActivity: Equatable {
    case none
    case downloading(TranscriberModel, progress: Double?)  // nil = indeterminate
    case loading(TranscriberModel)
}

var servingModel: TranscriberModel?        // model of the backend installed in the coordinator; nil until first install
var activity: ProvisioningActivity         // current provisioning work
var lastFailure: (model: TranscriberModel, message: String)?
// lastFailure is cleared when a USER-initiated provision starts (selection
// change or Retry) and on that cycle's success. The F2-chained provision and
// its success deliberately do NOT clear it — otherwise the reason for an
// auto-revert could never be shown in Settings.

var canStartRecording: Bool {
    activity == .none && servingModel != nil && servingModel == settings.transcriberModel
}
```

`servingModel` answers "can I record, and with what?"; `activity` +
`lastFailure` answer "what happened to the model I picked?". (A single scalar
state cannot answer both — the revised rules below depend on the split.)

**Wiring** (none of this exists today; `AppSettings` and `AppServices` are
currently unconnected): `TomeApp` hands `settings` to `AppServices` so the
provisioner can read and write the selection. Selection changes reach the
provisioner via the established pattern — `ContentView.onChange(of:
settings.transcriberModel)` → `provisioner.provision(model)` — and the launch
kick fires from ContentView's existing boot `.task`. Re-entrancy protection
lives **in the provisioner**, not in a suppressed `didSet`:
`provision(model:)` is a no-op when `model == servingModel && activity ==
.none`. Revert writes therefore go through the normal property write —
`didSet` still persists to UserDefaults (bypassing it would leave the failed
model in UserDefaults and surprise-provision it next launch) — and the
provisioning trigger they cause no-ops naturally.

**Generation guard:** every provisioning cycle carries a generation token.
Any outcome — state write, coordinator install, last-good persist, revert —
is **dropped if its token is no longer current**. This is load-bearing:
cancellation is cooperative and the SDK calls may not observe it promptly
(or at all during the load phase), so a superseded cycle can still complete
or fail later. Without the guard, a late failure would revert the user's
*new* selection, and a late success would install the *wrong* backend.

```
                 provision(M)  [selection onChange / launch kick / Retry]
                        │
        no-op if M == servingModel && activity == .none
                        │
        if M == servingModel && activity != .none  (flip BACK to the
        serving model mid-swap): cancel the in-flight cycle and set
        activity = .none — the serving backend is still installed, so
        nothing needs re-provisioning
                        │
        cancel in-flight cycle (its late outcomes are dropped by generation)
                        │
                        ▼
        downloading(M, pct) ──▶ loading(M) ──▶ ready:
              │                     │            coordinator.install(M-backend)
              │ error               │ error      old backend unload deferred (§3)
              ▼                     ▼            servingModel = M; lastGood = M
            failure handling (below)             activity = .none
```

(Cancellation does **not** route to failure handling — a cancelled cycle's
outcomes are simply dropped.)

**Failure handling** — on error in the *current* cycle for model M:
`activity = .none`, `lastFailure = (M, message)`, then exactly one of:

- **F1 — something else is serving** (`servingModel != nil`; ≠ M is
  guaranteed by the flip-back rule above, which never starts a cycle for the
  serving model):
  write `settings.transcriberModel = servingModel` (normal write; persists;
  the triggered `provision` no-ops). Recording is immediately available again
  on the serving backend. This is the common in-session revert.
- **F2 — nothing serving, last-good exists and ≠ M** (e.g. app relaunched
  mid-download, so nothing is resident, then the selected model fails offline):
  write `settings.transcriberModel = lastGood` and **provision it** (the guard
  doesn't block: lastGood ≠ servingModel since nothing is serving). The chain
  terminates: if last-good also fails, its failure lands in F3.
- **F3 — otherwise** (M is the last-good itself, or no model ever reached
  ready): selection stays M, `lastFailure` shows with Retry, recording stays
  disabled (nothing could transcribe anyway). This is the only
  recording-disabled resting state, and Retry is its recovery path.

**Retry** (Settings button) is `provisioner.retry()`: write
`settings.transcriberModel = lastFailure.model` (persists; may be a no-change
write) **and directly call `provision(lastFailure.model)`**. The direct call
is required: in F3 the selection already *is* the failed model, and writing
an unchanged value fires no `onChange` — a write-only Retry would be inert in
the one state it exists for. The selection write keeps picker, serving
backend, and last-good in lockstep on success. (For the same no-`onChange`
reason, re-selecting the currently selected item in the picker is not a retry
path; the Retry button is the only affordance in F3.) Retry is disabled under
the same conditions as the picker (§4a) — it swaps models just like a
selection change and must not land mid-job.

Remaining rules:

1. **Launch**: the boot task provisions `settings.transcriberModel`. Cached
   models (`isInstalled()`) skip the download phase and must load offline.
2. **App killed / crashed mid-download**: partial downloads are the SDKs'
   concern (resume/redownload on next attempt); relaunch simply provisions
   the selection again. If it fails with nothing resident, F2/F3 apply — no
   dead end.
3. **Cache deleted between launches** (user clears
   `~/Library/Application Support/FluidAudio/Models/` or Tome's WhisperKit
   `downloadBase`): discovered at next provision via `isInstalled()`;
   triggers a re-download, not a crash.
4. **Selecting the already-ready model**: no-op (the guard).
5. **Two rapid selection flips**: each flip cancels the prior cycle; the
   generation guard makes stale outcomes inert; the last selection wins.

### 4a. No swaps mid-job: picker gating beyond recording

Recording is not the coordinator's only consumer — post-processing
re-transcription runs *after* recording stops (`PostProcessingQueue` →
`SegmentReTranscriber`), and orphan recovery runs at launch and from
File ▸ Recover from WAV. A swap landing mid-job would re-transcribe half a
transcript with a different model.

- The Settings picker is disabled while **any** of: recording is active, a
  session is starting or stopping (the press→recording and stop→enqueue
  transition windows that `isRecording` misses — not the pre-recovery settle
  wait), a post-processing job is running (`postProcessingQueue` already exposes
  this; the menu bar observes it today), or a recovery re-transcription is in
  flight. Caption: "Model changes are disabled while recording or processing."
- `Recovery.run()` no longer calls `initialize()`; it **awaits the
  provisioner settling**, then proceeds on the installed backend.
  **Settled** is defined as a *resting* state: no cycle in flight **and**
  failure handling — including any chained F2 provision — has completed.
  (Failure handling momentarily passes through `activity == .none` before F2
  starts the last-good cycle; a settle defined naively on `activity` alone
  could wake in that gap, find nothing installed, and abort a recovery that
  the chained cycle was about to make possible.) — so launch-time orphan recovery cannot race the launch
  provisioning kick or start its own download. If nothing is installed after
  settle (F3 at first run), recovery aborts with a surfaced error; orphaned
  sessions stay on disk and are picked up on a later launch or manual
  File ▸ Recover.

### 5. TranscriptionEngine.start() interaction

- `start()` no longer loads ASR models. Its defensive check is: **verify the
  coordinator has an installed backend, else fail start with the existing
  `lastError` surfacing** — never keyed to the *selected* model and never
  download-initiating. (UI gating means this is normally a formality; the
  check exists for the API-start and race windows.) The VAD model load stays
  in `start()` unchanged.
- Status strings become model-parameterized but keep their API-matched shapes
  (see §7): `"Transcribing (Parakeet-TDT v3)"` →
  `"Transcribing (\(model.displayName))"`.

### 6. Settings UX (Settings ▸ Transcription)

New "Model" section **above** the existing read-only Language section:

- `Picker("Model", …)` with two rows, each showing **its own** install state
  as a subtitle (sourced from that backend's `isInstalled()`):
  - **Parakeet-TDT v3** — "fast, streaming-optimized (default)" ·
    "Downloaded ✓" / "Not downloaded (~600 MB)"
  - **Whisper Large v3 Turbo** — "higher accuracy, larger download" ·
    "Downloaded ✓" / "Not downloaded (~0.6–1.5 GB, resolved per device)"
- A status line under the picker reflecting the **selected** model:
  - `activity == .downloading` → "Downloading… 42%" ("Downloading…" when
    progress is nil)
  - `activity == .loading` → "Loading model…"
  - `lastFailure != nil` → its message + **Retry** button (defined and gated
    in §4/§4a; note the failure may name the *previously selected* model
    after an auto-revert — display it with the failed model's name)
  - otherwise, `servingModel == selection` → "Active ✓"
  - otherwise (transient frames: pre-launch-kick, or the gap between a
    selection write and its `onChange` firing) → render as "Loading model…";
    these frames resolve as soon as the pending kick/`onChange` runs
- Picker disabled per §4a with the caption above.
- Sizes in copy are derived from the resolved Whisper variant (§2), not
  hardcoded.

### 7. Main screen (ControlBar) and API

- Both record buttons gate on the single source of truth
  `provisioner.canStartRecording` (§4) — as do their keyboard shortcuts, the
  menu-bar start items, and **both** API start endpoints (`POST /start` and
  `POST /sessions/start`), which return a "model not ready" error instead of
  silently failing.
- ControlBar renders provisioning status **directly from the provisioner's
  observable state** (new view input), not by threading it through
  `assetStatus` — the API string-matches `assetStatus`, and polluting it with
  new states would break `GET /health`'s `modelsReady` derivation:
  - `downloading` → **"DOWNLOADING MODEL… 42%"** (display-uppercased)
  - `loading` → **"LOADING MODEL…"**
  - failure after revert (F1/F2) → line via the existing `errorMessage` row:
    "Whisper download failed — reverted to Parakeet-TDT v3: <reason>". It
    persists (driven by `lastFailure`) until the next user-initiated
    provisioning action clears it — recording is already available again on the
    reverted-to backend — and sits behind the engine's own `lastError` in
    precedence, so a live capture/write error still takes the row.
  - failure at rest (F3) → persistent "MODEL DOWNLOAD FAILED — retry in
    Settings ▸ Transcription", buttons disabled.
  - the transient not-yet-provisioning frames (§6) → "LOADING MODEL…".
- `GET /health`'s `modelsReady` is re-sourced from
  `provisioner.canStartRecording` (semantics preserved — "a recording can
  start now" — response shape untouched, respecting the upstream API freeze).
  `handleSessionStatus`'s `contains("Loading")`/`contains("Initializing")`
  matching is audited against the final `assetStatus` strings, which this
  design deliberately leaves shape-compatible (§5).

### 8. Load testing: Whisper v3 Turbo vs Parakeet for live use

New CLI target **`ASRBench`** (pattern: existing `VoiceprintAudit` CLI target).
Run manually on Nic's machine — **not** in CI (CI can't download models or
guarantee ANE availability).

- Input: one or more 16 kHz mono WAV fixtures (a real recording; the CLI also
  accepts any WAV and resamples like `StreamingTranscriber` does).
- Method: replays the audio through both backends with the same chunking the
  live pipeline produces (VAD-bounded segments, up to the ~30 s flush window),
  measuring per chunk.
- Report, per backend: resolved model variant + download size on disk; model
  load time (cold and warm); first-transcription latency (ANE warm-up — known
  Whisper cost); per-chunk latency p50/p95; real-time factor (RTF); peak
  resident memory.
- **Acceptance bar for live use: p95 chunk latency comfortably under chunk
  duration — RTF < ~0.5.** If Whisper misses the bar, the feature still ships;
  the drop-down copy gains "may lag during live transcription" and the numbers
  go in the PR description for a follow-up decision.

### 9. Testing strategy

**Unit tests (CI, no real models):** a `FakeBackend` with scriptable prepare
behavior (succeed after N events, fail with error E, hang until cancelled,
complete/fail *after* cancellation). Provisioner + coordinator tests:

1. select → downloading → loading → ready; coordinator swaps; `servingModel`,
   last-good, and selection all equal the new model.
2. download failure with a serving backend (F1) → selection reverted via the
   normal write — **UserDefaults contains the reverted selection afterward** —
   no re-provisioning triggered (guard no-op), `canStartRecording` true again.
3. failure with nothing serving and last-good ≠ failed (F2) → selection
   becomes last-good **and last-good is provisioned**; `lastFailure` survives
   the chained cycle and its success (Settings can show why the revert
   happened); chain ends in F3 if it also fails.
4. failure with no last-good, and failure where failed == last-good (both F3)
   → stays failed; `retry()` re-enters the machine **despite the selection
   value being unchanged** (the direct `provision` call, not `onChange`, is
   what fires).
5. cancel mid-download by re-selecting → no failure handling runs; new model
   provisions; **late failure from the cancelled cycle → no revert, no
   lastFailure; late success → no install, no last-good update** (generation
   guard).
6. selecting the already-serving model → no-op.
7. **unload discipline**: transcribe hung on the old FakeBackend while
   `install()` runs → the in-flight call completes on the old backend;
   `unload()` fires only after it returns; concurrent new calls use the new
   backend.
8. last-good is absent until first ready; persists and round-trips (restart
   scenario). Unknown persisted raw values: `transcriberModel` falls back to
   Parakeet; `lastGoodTranscriberModel` is treated as **absent** (a Parakeet
   fallback there would recreate the fresh-install ambiguity §1 forbids).
9. flip back to the serving model mid-download → in-flight cycle cancelled,
   `activity = .none`, no re-provision, recording available immediately.
10. Retry lockstep: fail → revert → Retry → success asserts picker selection,
   `servingModel`, and last-good all equal the retried model.

**Existing suite:** all `TomeTests` from `resilience-full` stay green
(`swift test`, `DEVELOPER_DIR` pointing at full Xcode).

**Smoke tests (manual, on-device):** for **each** model: record a short call
capture and a voice memo → live transcript appears → stop → post-processing
completes → final transcript written. Plus: flip models mid-idle; kill network
and select the un-downloaded model (observe revert + error UX); Retry from
Settings; delete `~/Library/Application Support/FluidAudio/Models/` (and the
WhisperKit downloadBase) between launches → re-download; verify picker is
disabled during post-processing.

**State-audit agent pass (final gate):** an agent enumerates the matrix —
{selected model} × {installed / not installed} × {network up / down} ×
{recording active / **post-processing or recovery in flight** / idle} ×
{app relaunched mid-download} × {cache deleted between launches} ×
{first run / has last-good / last-good itself fails} — and traces each cell
through the implemented code, hunting specifically for: recording disabled
with no recovery path, failures with no Retry affordance, revert recursion,
selection/serving/last-good desync, stale-generation outcomes mutating state,
unload-under-use, and stale UI (button says downloading, nothing in flight).
Findings are fixed before the branch is called done.

## Risks & open items

- **WhisperKit download-progress callback shape** in the pinned revision needs
  confirmation at implementation start (the model registry, variant list, and
  offline-load path were already verified against the pinned checkout during
  spec review; only the progress-callback ergonomics remain).
- **Whisper live latency is unknown** until ASRBench runs — the design
  deliberately ships the drop-down regardless and lets the numbers drive copy.
- **Memory**: two models co-resident during a swap (old serving, new loading)
  is the peak; steady state is one model.
- Upstream (`dloomis/Tome`) API surface is frozen pending discussion — this
  design changes no response shapes; `/health` semantics are preserved and
  both start endpoints gain only an error response.

## Out of scope

Per-source model selection, model auto-selection heuristics, download pause /
resume UI, deleting downloaded models from Settings, locale picker.
