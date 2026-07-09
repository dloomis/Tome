# ASRBench Results — Parakeet vs Whisper Large v3 Turbo

Task 12 (full verification + benchmark run) for branch `whisper-v3-turbo-model-option`.

## Machine

- Chip: Apple M2 Max (`sysctl -n machdep.cpu.brand_string`)
- RAM: 64 GB / 68719476736 bytes (`sysctl -n hw.memsize`)
- macOS: 26.2 (`sw_vers -productVersion`)

## Step 1: Full build + suite + selfcheck (CI parity)

`swift build` (whole workspace) hit the pre-existing, documented flake: the type-checker
timeout inside FluidAudio's vendored checkout CLI
(`.build/checkouts/FluidAudio/Sources/FluidAudioCLI/Commands/ASR/Parakeet/Streaming/NemotronMultilingualFleursBenchmark.swift:790`,
`"the compiler is unable to type-check this expression in reasonable time"`). Reproduced on
two consecutive attempts. This is **not** a regression introduced by this branch — it's inside
FluidAudio's own CLI sources, unrelated to Tome or ASRBench code. Per the task's operational
notes, fell back to the equivalent gate:

```
cd /Users/nic/programming/tome/Tome
swift build --target Tome        # SUCCESS (0.22s, incremental)
swift build --target ASRBench    # SUCCESS (0.17s, incremental)
DEVELOPER_DIR=/Applications/Xcode.app swift test
swift run Tome --selfcheck
```

**Results:**
- `swift build --target Tome` — SUCCESS
- `swift build --target ASRBench` — SUCCESS
- `swift test` — **84/84 tests PASS**, 16 suites, 0.267s (`Test run with 84 tests in 16 suites passed after 0.267 seconds.`)
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
  (The screen-recording WARN is expected/non-blocking — this machine's TCC state, not a code issue.)

**Step 1 verdict: PASS.**

## Step 2: Speech fixture

```
mkdir -p /tmp/asrbench
say -o /tmp/asrbench/fixture.aiff "$(python3 -c "print(('The quarterly infrastructure review covered database migration timelines, service level objectives, and the incident retrospective from last Tuesday. [[slnc 1200]] ' * 30))")"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/asrbench/fixture.aiff /tmp/asrbench/fixture.wav
```

Result: `/tmp/asrbench/fixture.wav` — 1 ch, 16000 Hz, Int16 PCM, **estimated duration 269.4 s**
(well above the ≥120s bar; 30 sentence+pause repeats as specified).

**Step 2 verdict: PASS.**

## Step 3: Run the bench — BLOCKED

`swift run -c release ASRBench /tmp/asrbench/fixture.wav --json /tmp/asrbench/results.json`
was attempted **7 times**. Parakeet-TDT v3 was already cached on this machine (from prior
Tome usage) and would have loaded/run without a fresh download. Every single attempt failed
**before Parakeet's report ever printed**, at the Whisper Large v3 Turbo download step, with
the identical fatal error:

```
Swift/ErrorType.swift:254: Fatal error: Error raised at top level: ArgmaxCore.Hub.HubClientError.downloadError("The request timed out.")
```

`~/Library/Application Support/Tome/WhisperKit` was never created in any attempt — zero bytes
of the Whisper model ever landed on disk.

### Diagnosis (not a fabrication — this is a genuine, reproducible blocker)

This is the known operational flake category ("if killed mid-download, just re-run it") **except**
retrying did not resolve it — the failure was deterministic across 7 attempts, not a one-off
network blip. Investigation traced the exact cause:

- Manual `curl` tests to the exact Hugging Face endpoints ASRBench uses all succeeded fast and
  cleanly from this machine (wired ethernet, correct system clock):
  - `GET https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/revision/main` → 200 in 0.12s
  - `GET .../resolve/main/openai_whisper-large-v3-v20240930/config.json` → 200 in 0.17s
  - `GET .../TextDecoder.mlmodelc/weights/weight.bin` (344 MB, the actual large weight file,
    redirects to Hugging Face's Xet CDN at `us.aws.cdn.hf.co`) → 200, TTFB 0.25s, full 344 MB
    in 4.06s
- So the network path itself, DNS resolution, and the CDN are healthy and fast.
- A dedicated code-reading pass through the vendored `argmax-oss-swift` package
  (`Tome/.build/checkouts/argmax-oss-swift/Sources/ArgmaxCore/External/Hub/`) found the root
  cause: `Downloader.swift:102` hardcodes `timeout: TimeInterval = 10` as the default for the
  actual per-file GET (applied at `Downloader.swift:195` as `request.timeoutInterval`, governing
  the streaming transfer at `Downloader.swift:251`, `session.bytes(for:)`). No caller in
  `HubApi.swift` (the `HubFileDownloader.download` call site at line 554, nor any `snapshot(...)`
  overload) passes a longer value, and there is no environment variable or public API to raise it.
  It is a "no bytes for 10s" watchdog, not a total-duration timeout, so it should tolerate a slow
  transfer — but something about `URLSession.bytes(for:)`'s handling of this specific presigned
  Xet CDN URL stalls past 10s in a way plain `curl` does not reproduce.
- Tried `CFNETWORK_HTTP3_ENABLED=0` (ruling out an HTTP/3 QUIC-negotiation stall specific to
  `URLSession`'s streaming API) — did not change the outcome; failure reproduced identically.
- This is entirely inside the vendored `argmax-oss-swift` dependency (pinned commit per the
  plan's tech stack, not code owned by this branch or by Tome). Patching a vendored checkout is
  out of scope for a verification/benchmark task and was not attempted.

**Because the benchmark could not complete, no Whisper RTF/latency numbers were produced.
Per the task's explicit instruction, no numbers are fabricated here.**

### What this means for Step 4/5

Step 4 (record results + PASS/MISS verdict) and the Step 4 MISS branch (picker-copy change)
cannot be executed as specified — there is no Whisper p95 RTF to compare against the spec §8
acceptance bar (p95 RTF < 0.5), so no PASS/MISS verdict can be honestly rendered. Filing this
as BLOCKED rather than guessing. No copy change to `TranscriberModel.pickerSubtitle` has been
made — that decision needs a real benchmark run once the download blocker is resolved (e.g. on
a machine/network where the Xet CDN transfer doesn't stall past the SDK's 10s watchdog, or after
`argmax-oss-swift` is updated/patched to expose a longer timeout).

## Step 5: Commit

Only this results doc is committed (recording the PASS build/test/selfcheck gate and the
BLOCKED benchmark with full diagnostic evidence). No picker-copy change was made since Step 4
could not produce a verdict.
