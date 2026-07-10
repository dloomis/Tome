# ASRBench Results — Parakeet vs Whisper Large v3 Turbo

Task 12 (full verification + benchmark run) for branch `whisper-v3-turbo-model-option`.

**Status: PASS.** Both report blocks were produced end-to-end with the Whisper cache fully
pre-seeded and zero network calls. Whisper Large v3 Turbo's p95 RTF is 0.130, comfortably under
the spec §8 live-use bar of < 0.5.

## Machine

- Chip: Apple M2 Max (`sysctl -n machdep.cpu.brand_string`)
- RAM: 64 GB / 68719476736 bytes (`sysctl -n hw.memsize`)
- macOS: 26.2, build 25C56 (`sw_vers`)

## Resolved Whisper variant

`openai_whisper-large-v3-v20240930` (full precision, ~1.5 GB) — this M2 Max supports the
full-precision family, so `WhisperBackend.resolveVariant()` does not fall back to `_626MB`
(confirmed by `resolveVariantPrefersFullPrecisionWhenSupported` passing in the suite on this
machine, and by the on-disk tree matching ASRBench's expected folder exactly).

## The fix

`Tome/Sources/ASRBench/main.swift`'s `benchWhisper` had a latent bug: the `cached` check only
gated *whether `downloadSeconds` got recorded*, not whether `WhisperKit.download(...)` was
called at all — the call was unconditional. On a network where `URLSession` cannot reach the
Hugging Face Xet CDN (see Known issue below), this killed the bench even with a fully
pre-seeded, valid on-disk cache. Mirrored the correct shape already used by
`WhisperBackend.prepare()` (`Tome/Sources/Tome/Transcription/WhisperBackend.swift:57-74`):
download only when the model is not already installed.

```swift
let folder: URL
var downloadSeconds: Double? = nil
if cached {
    folder = expectedFolder
} else {
    let tDownload = now()
    folder = try await WhisperKit.download(
        variant: variant, downloadBase: base,
        progressCallback: { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 10 == 0 { print("whisper download: \(pct)%") }
        })
    downloadSeconds = now() - tDownload
}
```

With the pre-seeded cache in place, this fix was sufficient to unblock the run — no download
was attempted, confirmed by both report blocks printing `download: cached`.

## Step 1: Full build + suite + selfcheck (CI parity) — PASS

Whole-workspace `swift build` hit the pre-existing, documented flake: the type-checker timeout
inside FluidAudio's vendored checkout CLI
(`.build/checkouts/FluidAudio/Sources/FluidAudioCLI/Commands/ASR/Parakeet/Streaming/NemotronMultilingualFleursBenchmark.swift:790`).
Not a regression of this branch. Used the documented equivalent gate:

- `swift build --target Tome` — SUCCESS
- `swift build --target ASRBench` — SUCCESS
- `swift test` — **84/84 tests PASS**, 16 suites

## Step 2: Speech fixture — PASS

`say` + `afconvert` per the brief: `/tmp/asrbench/fixture.wav`, 1 ch / 16 kHz / Int16 PCM,
**269.4 s** (bar: ≥120 s). ASRBench's VAD segmented it into **30 chunks of 7.9–8.1 s** —
exactly the ~30 utterance-sized chunks the fixture was designed to produce.

## Step 3: Benchmark run — PASS

```
cd /Users/nic/programming/tome/Tome
swift run -c release ASRBench /tmp/asrbench/fixture.wav --json /tmp/asrbench/results.json
```

Full console output, verbatim:

```
loaded /tmp/asrbench/fixture.wav: 269s
VAD chunks: 30 (7.9s–8.1s)

== Parakeet-TDT v3 (parakeet-tdt-0.6b-v3 int8) ==
download:        cached
on disk:         461 MB
load cold/warm:  0.2s / 0.1s
first transcribe (warm-up): 0.12s
chunk latency:   p50 0.10s  p95 0.10s
RTF:             p50 0.012  p95 0.013
peak RSS:        159 MB
chunks:          30 totaling 243s

== Whisper Large v3 Turbo (openai_whisper-large-v3-v20240930) ==
download:        cached
on disk:         1545 MB
load cold/warm:  16.9s / 0.5s
first transcribe (warm-up): 1.59s
chunk latency:   p50 1.03s  p95 1.03s
RTF:             p50 0.126  p95 0.130
peak RSS:        1361 MB
chunks:          30 totaling 243s

Acceptance bar (spec §8): live use wants p95 RTF < 0.5.
Whisper p95 RTF = 0.130 → PASS
wrote /tmp/asrbench/results.json
```

No download progress lines appeared for either backend — both report blocks show
`download: cached`, confirming the fix works and no network calls occurred. Whisper's cold
load (16.9s) reflects ANE compilation on first load, as expected for a fresh process; the warm
load (0.5s) shows the compiled artifacts are otherwise fast to instantiate.

### Chunk stats

| Backend | Chunks | Chunk duration range | Latency p50 | Latency p95 | RTF p50 | RTF p95 |
|---|---|---|---|---|---|---|
| Parakeet-TDT v3 | 30 | 7.88s–8.14s | 0.10s | 0.10s | 0.012 | 0.013 |
| Whisper Large v3 Turbo | 30 | 7.88s–8.14s | 1.03s | 1.03s | 0.126 | 0.130 |

Both backends processed the same 30 chunks (243s of audio total). Parakeet is roughly 10×
faster than Whisper on this machine, but both are well within the real-time budget.

## Verdict

**PASS.** Spec §8 acceptance bar: Whisper p95 RTF < 0.5 for live use.

- Parakeet-TDT v3: p95 RTF = **0.013** (≈38× under the bar)
- Whisper Large v3 Turbo: p95 RTF = **0.130** (≈3.8× under the bar)

Both backends comfortably clear the live-use latency bar on this machine (Apple M2 Max, 64 GB).
**Decision: no copy change needed.** `TranscriberModel.pickerSubtitle` for
`.whisperLargeV3Turbo` keeps its plain drop-down copy — Whisper does not "lag during live
transcription" on hardware in this class, so the more cautionary copy is not warranted. No
change was made to `Tome/Sources/Tome/Transcription/TranscriberModel.swift`.

## Known issue: Whisper download unreachable via the SDK on this network

This was the blocker for the *previous* run of this task (see git history for the prior
version of this doc, commit `734b9d7`) and is unrelated to the ASRBench fix above — it is an
upstream/network condition, not a Tome or ASRBench bug. Recorded here for continuity since it's
why the cache had to be pre-seeded out-of-band for this run to be possible at all.

1. On this network, `URLSession`-based downloads (both the vendored `argmax-oss-swift` SDK and
   a minimal Swift repro using `URLSession.shared.bytes(for:)`) cannot connect to the Hugging
   Face Xet CDN host (`us.aws.cdn.hf.co`) at all, at any timeout — raising the SDK's hardcoded
   10 s timeout to 75 s did not help (fails at 76 s instead of 10 s). This rules out the
   10-second timeout as the root cause; the connection itself never establishes via
   `URLSession`.
2. `curl` reaches the same host and every one of its A records without issue (TLS connect in
   ~30 ms, full 344 MB weight file fetched in 4.1 s). `python urllib` fails the same way
   `URLSession` does. This points to a client/network-stack interaction specific to
   non-curl HTTP clients on this network (e.g. happy-eyeballs/IPv6 or middlebox behavior),
   not a CDN, DNS, or slowness problem.
3. Because of this, Whisper's on-disk cache for this run was **pre-seeded out-of-band** (curl
   fetch of the full `openai_whisper-large-v3-v20240930` variant tree plus tokenizer files,
   1.5 GB total, placed directly into
   `~/Library/Application Support/Tome/WhisperKit/models/...`). **Download time for Whisper is
   therefore not measured by this run** — `download: cached` in both report blocks reflects
   that pre-seeded state, not a real download-then-cache cycle.
4. A follow-up task has been filed to address the underlying `URLSession`/Xet-CDN
   connectivity issue upstream (or add a documented offline/skip-if-cached mode to the
   vendored SDK). This was **not** fixed as part of this task — out of scope, and the ASRBench
   fix in this commit (skip `WhisperKit.download` entirely when already cached) is the correct,
   minimal, permanent fix regardless of whether the network issue is ever resolved: it makes
   ASRBench behave exactly like the app's own `WhisperBackend.prepare()`, which already has
   this shape.
