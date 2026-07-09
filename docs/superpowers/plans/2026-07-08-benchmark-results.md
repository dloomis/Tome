# ASRBench Results — Parakeet vs Whisper Large v3 Turbo

Task 12 (full verification + benchmark run) for branch `whisper-v3-turbo-model-option`.

**Status: BLOCKED for Whisper (environment, not code). Parakeet's full report was produced;
Whisper's could not be — see Known issue below. No PASS/MISS verdict is rendered and no
numbers are fabricated.**

## Machine

- Chip: Apple M2 Max (`sysctl -n machdep.cpu.brand_string`)
- RAM: 64 GB / 68719476736 bytes (`sysctl -n hw.memsize`)
- macOS: 26.2 (`sw_vers -productVersion`)

## Resolved Whisper variant

`openai_whisper-large-v3-v20240930` (full precision, ~1.5 GB) — this M2 Max supports the
full-precision family, so `WhisperBackend.resolveVariant()` does not fall back to `_626MB`
(confirmed by `resolveVariantPrefersFullPrecisionWhenSupported` passing in the suite on this
machine, and by the pre-seeded on-disk tree matching ASRBench's expected folder).

## Step 1: Full build + suite + selfcheck (CI parity) — PASS

Whole-workspace `swift build` hit the pre-existing, documented flake: the type-checker timeout
inside FluidAudio's vendored checkout CLI
(`.build/checkouts/FluidAudio/Sources/FluidAudioCLI/Commands/ASR/Parakeet/Streaming/NemotronMultilingualFleursBenchmark.swift:790`),
reproduced on two consecutive attempts. Not a regression of this branch. Per the operational
notes, used the equivalent gate:

- `swift build --target Tome` — SUCCESS
- `swift build --target ASRBench` — SUCCESS
- `DEVELOPER_DIR=/Applications/Xcode.app swift test` — **84/84 tests PASS**, 16 suites
- `swift run Tome --selfcheck` — **RESULT: OK**, exit code 0:
  ```
  Tome self-check
    [PASS] sessions directory: /Users/nic/Library/Application Support/Tome/sessions
    [PASS] WAV writer: wrote+read 4800 frames
    [PASS] microphone permission: granted
    [WARN] screen recording permission: not granted (system audio capture unavailable)
    [PASS] API port file: /Users/nic/Library/Application Support/Tome/api-port
  RESULT: OK
  ```
  (The WARN is this machine's TCC state, expected and non-blocking.)

## Step 2: Speech fixture — PASS

`say` + `afconvert` per the brief: `/tmp/asrbench/fixture.wav`, 1 ch / 16 kHz / Int16 PCM,
**269.4 s** (bar: ≥120 s). ASRBench's VAD segmented it into **30 chunks of 7.9–8.1 s** —
exactly the ~30 utterance-sized chunks the fixture was designed to produce.

## Step 3: Benchmark run

```
cd /Users/nic/programming/tome/Tome
swift run -c release ASRBench /tmp/asrbench/fixture.wav --json /tmp/asrbench/results.json
```

Console output (captured via pty; ASRBench's stdout is block-buffered through a pipe and the
`fatalError` was discarding it — the pty run recovered the full log):

```
loaded /tmp/asrbench/fixture.wav: 269s
VAD chunks: 30 (7.9s–8.1s)

== Parakeet-TDT v3 (parakeet-tdt-0.6b-v3 int8) ==
download:        cached
on disk:         461 MB
load cold/warm:  0.2s / 0.1s
first transcribe (warm-up): 0.12s
chunk latency:   p50 0.09s  p95 0.10s
RTF:             p50 0.012  p95 0.013
peak RSS:        157 MB
chunks:          30 totaling 243s
Swift/ErrorType.swift:254: Fatal error: Error raised at top level: ArgmaxCore.Hub.HubClientError.downloadError("The request timed out.")
```

**Parakeet-TDT v3: complete.** p50 RTF 0.012 / p95 RTF 0.013 — roughly 40× under the spec §8
live-use bar (p95 RTF < 0.5), on cached models with no network involvement.

**Whisper Large v3 Turbo: no report block.** The process dies inside `benchWhisper` at the
unconditional `WhisperKit.download(...)` call (`Tome/Sources/ASRBench/main.swift:130`) — see
Known issue. `--json` output was never written (the process aborts before reports are encoded).

## Verdict

**No PASS/MISS verdict can be rendered.** The acceptance bar (spec §8: Whisper p95 RTF < 0.5
for live use) requires Whisper chunk timings that this environment cannot produce. The decision
it would drive — plain drop-down copy vs adding "may lag during live transcription" to
`TranscriberModel.pickerSubtitle` for `.whisperLargeV3Turbo` — is deferred; **no copy change
has been made**. The benchmark must be re-run on a machine/network without the URLSession
blocker below (or after the vendored SDK gains an offline/skip-if-cached path).

## Known issue: Whisper download unreachable via the SDK on this network

Chronology and evidence (9 total ASRBench invocations: 7 before cache seeding, 2 after, plus
2 diagnostic minimal-repro programs):

1. Every ASRBench run fails identically with
   `ArgmaxCore.Hub.HubClientError.downloadError("The request timed out.")`. Before cache
   seeding, zero Whisper bytes ever landed on disk.
2. **Whisper's on-disk cache was then manually pre-seeded outside the SDK** (curl fetch of the
   full `openai_whisper-large-v3-v20240930` variant tree into
   `~/Library/Application Support/Tome/WhisperKit/models/argmaxinc/whisperkit-coreml/…`, plus
   the `openai/whisper-large-v3` tokenizer files; 1.5 GB total). **Download time is therefore
   not measurable via the SDK on this network.**
3. Pre-seeding did not unblock ASRBench: its cached-check (`main.swift:127-128`) only decides
   whether to *record* `downloadSeconds` — it still calls `WhisperKit.download(...)`
   unconditionally (`main.swift:130`), and the SDK's snapshot/revalidation path still reaches
   for the network.
4. Root cause is a client-stack/network interaction, **not** the CDN and **not** simple
   slowness:
   - `curl` fetches everything, fast: the HF API listing (0.12 s), `config.json` (0.17 s), and
     the actual 344 MB `TextDecoder.mlmodelc/weights/weight.bin` through its redirect to the
     Xet CDN `us.aws.cdn.hf.co` (TTFB 0.25 s, full file in 4.1 s). All five individual A
     records of `us.aws.cdn.hf.co` accept TLS connections via curl in ~30 ms.
   - A minimal Swift repro of the SDK's exact mechanics (`URLSession.shared.bytes(for:)`,
     `timeoutInterval = 10` — mirroring vendored
     `argmax-oss-swift/Sources/ArgmaxCore/External/Hub/Downloader.swift:102/195/251`) fails
     deterministically with "The request timed out." — on the redirect URL **and** on the
     presigned CDN URL directly. Raising the timeout to 75 s does not help (fails at 76 s):
     the connection never establishes, so the SDK's hardcoded 10 s timeout is *not* the root
     cause on this network (though it remains a legitimate upstream issue — no override
     parameter or env var exists; a follow-up task has been filed; deliberately **not** fixed
     in this branch).
   - `URLSession` *can* reach `huggingface.co` itself (API GET succeeds in 0.11 s). The failure
     is specific to the Xet CDN host. `python urllib` also times out on this network; curl is
     the only client that connects reliably — consistent with a client/network-stack
     interaction (e.g. happy-eyeballs/IPv6 or middlebox behavior differing by TLS/socket
     stack), not an ASRBench or Tome bug.
5. Not fixed here because: the failure is in the vendored `argmax-oss-swift` dependency +
   local network environment; patching a checkout is out of scope for a verification task and
   was explicitly ruled out; ASRBench itself is a deliverable of this branch and rewriting its
   download flow mid-verification would change the thing being verified.

### What unblocking looks like

Any of: run on a network where `URLSession` can reach `us.aws.cdn.hf.co`; or an SDK update
exposing a skip-if-cached/offline mode (follow-up task filed); after either, re-run Step 3 and
fill in the Whisper report block + verdict here.
