# Own-Voice Bleed into System-Audio Capture — Audio-Router Exclusion

**Date:** 2026-07-24
**Status:** Implemented 2026-07-24 (mechanism verified empirically on the reproduction machine; `swift test` green, 160 tests)
**Type:** Defect + hardening

**As-shipped deviations from the design below:**
- The end-of-session "system audio was silent" note is a stop-time
  notification (fixed ID, replaces the 60s mid-session warning) rather than an
  append to the save banner — same user outcome without threading a flag
  through `SessionHandle`/`PostProcessingJob`/`JobCompletion`. Gated to
  sessions ≥ 60s so quick test stops don't nag.
- Seeded exclusion defaults are the two verified Elgato IDs only
  (`com.elgato.WaveLink3`, `com.elgato.WaveLink`); the other candidates in the
  table remain user-addable pending bundle-ID verification, per the "ship only
  verified IDs" rule.
- The digital-silence detector also self-clears: if real audio arrives later
  (user unmutes, router app launches), the warning and notification are
  withdrawn.

## Problem

With Elgato Wave Link running, Tome's system-audio leg records the local
user's own microphone voice. The same speech is transcribed twice — once on
the mic leg as `YOU`, once on the system leg as `THEM`. Quitting Wave Link
eliminates the duplication. Full observed behavior, ruled-out hypotheses, and
reproduction environment: see the problem statement (2026-07-24 session).

## Verified mechanism

The working hypothesis — ScreenCaptureKit captures audio **per application
process**, and Wave Link's mix rendering is visible to SCK as Wave Link app
audio — is **CONFIRMED**. Verification was run live on the reproduction
machine (macOS 26.5 SDK, Wave Link 3.2.2, Wave XLR Dock MK.2 + MV7+) with the
harness preserved in `assets/2026-07-24-sckprobe/`:

1. **Process attribution (CoreAudio, no TCC needed).** `caprobe` enumerates
   `kAudioHardwarePropertyProcessObjectList`. With Wave Link running and
   *nothing* playing and no call active, `com.elgato.WaveLink3` was the
   **only** process object on the system with `IsRunning=1 IsRunningInput=1
   IsRunningOutput=1` — it continuously pulls the mic and renders output
   audio the moment the app launches. This per-process output activity is
   exactly what SCK's audio tap mixes.

2. **Content: include-only Wave Link** (`sckprobe capture 8
   only:com.elgato.WaveLink3`, quiet room): live signal — 361,503 non-zero
   frames of 402,240, RMS −98.8 dBFS (mic noise floor / room ambience through
   the Wave Link mix). Wave Link's rendered mix is captured as its app audio.

3. **Content: exclude Wave Link** (`exclude:com.elgato.WaveLink3`): **exact
   digital silence** — 0 non-zero frames of 394,560. Excluding the Wave Link
   app removes 100% of the bleed signal.

4. **Content: display-wide** (Tome's current filter shape): non-zero — the
   bleed path reproduces in the harness exactly as in Tome.

5. **§6 design tension resolved — far-end audio survives exclusion.** With
   Wave Link *excluded* and `say` speaking through the default output (the
   XLR Dock, i.e. "routed where Wave Link monitors"), the speech WAS captured
   (peak 0.091, RMS −52 dBFS during speech; exact zeros otherwise). SCK
   attributes app audio to the **source process** that renders it, not to the
   device it is routed to and not to Wave Link's re-render. A conferencing
   app's far-end audio therefore survives Wave Link exclusion even when its
   output is routed through a Wave Link device.

6. **Wave Link double-captures other apps too.** With Wave Link *included
   only*, the same `say` speech appeared at RMS −27 dBFS — Wave Link
   re-renders system audio into its mixes at higher gain. So today's bug is
   not limited to own-voice: far-end audio is also captured twice (source
   copy + Wave Link's mix copy). The two copies are near-simultaneous, which
   is why the visible symptom was own-voice duplication; excluding Wave Link
   fixes both.

7. **The alternate hypothesis (SCK taps the default output device) is
   refuted** by (3): the default output device and all routing were untouched
   while excluding one *application* zeroed the capture.

Two additional facts established during verification:

- **SCK delivers sample buffers continuously even when the captured content
  is pure digital silence** (~50 buffers/s of exact-zero frames in test 3).
  Consequence: the existing startup-delivery gate
  (`TranscriptionEngine.armSystemStartupDeliveryGate`, keyed on
  `firstSampleTime`) and the 15s stall watchdog **cannot detect an empty
  system leg** — delivery never stops. Detection must be content-aware
  (§ Part B), which revises acceptance criterion 4 below.
- `SCStreamConfiguration.excludesCurrentProcessAudio` is already set
  (`SystemAudioCapture.swift:123`); per §5 of the problem statement it is
  unrelated to this defect (Tome's pid ≠ Wave Link's pid, confirmed in
  `caprobe` output).

SDK survey (macOS 26.5): SCK audio filtering is per-`SCRunningApplication`
only — no per-device scoping. CoreAudio process taps (`CATapDescription` +
`AudioHardwareCreateProcessTap`) do offer device-scoped and
process-excluding taps (incl. `bundleIDs` and `processRestoreEnabled` on
macOS 26). That is a plausible future re-architecture (§ Out of scope), not
needed for this fix.

## Design

Four parts. A is the fix; B–D are the hardening items from §7 of the problem
statement.

### Part A — Settings-backed audio-router exclusion list

Generalize the existing `noiseAppBundleIDs` exclusion mechanism
(`SystemAudioCapture.swift:56`) with a user-editable list of **audio-router
applications** whose app audio must never enter the system leg.

**Safety argument** (extends the 2026-07-10 inclusion-filter invariant): the
filter remains display-wide with *exclusions only*. Exclusion of a router is
safe because (verified, item 5) the far-end copy captured on the system leg
is attributed to the conferencing app's own process; the router's re-render
is a duplicate. The one genuine loss case — far-end audio that *enters the
Mac through the router itself* (e.g. a hardware mixer feeding a second
computer's audio in as an input) — is covered by Part B's audible-silence
warning plus the list being editable.

**`AppSettings`** (new, UserDefaults-backed, following existing patterns):

- `excludedAudioAppIDs: [String]` — effective exclusion list. Key
  `excludedAudioAppIDs`.
- `excludedAudioAppSeenDefaults: [String]` — every built-in default ever
  offered to this install. On `init`, any built-in default not in this set is
  appended to both keys. User removals stick (removed IDs stay in
  `seenDefaults`), and future releases can add new defaults without
  resurrecting deleted ones.

**Built-in defaults** (ship only IDs verified against a real install or
vendor artifact; an ID that never matches is a silent no-op, which is why
verification matters — a wrong ID is *unprotection*, not breakage):

| App | Bundle ID | Provenance |
|---|---|---|
| Elgato Wave Link 3 | `com.elgato.WaveLink3` | **Verified** on repro machine (`osascript`, Info.plist, v3.2.2) |
| Elgato Wave Link 1.x | `com.elgato.WaveLink` | Unverified — verify or drop at implementation |
| Rogue Amoeba Loopback | `com.rogueamoeba.Loopback` | Unverified — verify at implementation |
| Audio Hijack | `com.rogueamoeba.audiohijack` | Unverified — verify at implementation |
| Krisp | `ai.krisp.krispMac` | Unverified — verify at implementation |
| Voicemod | (lookup) | Unverified — verify at implementation |
| Shure MOTIV Mix | (lookup) | Unverified — mixes/monitors mics + system audio in-app (Wave Link-analog for Shure MV-series; the repro machine's MV7+ is a supported device) |
| RØDE Connect / UNIFY | (lookup) | Unverified — in-app podcast mixing over virtual devices |
| Ginger Audio GroundControl | (lookup) | Unverified — Wave Link-style mixer |
| Logitech G HUB (Blue Vo!ce) | (lookup) | Unverified — confirm whether mic FX render in the G HUB process on macOS |

Not defaults, documented in the Settings help text instead:

- **Driver-only virtual devices — BlackHole, VB-Cable**: pure HAL drivers, no
  app process renders audio, so there is nothing to exclude and the own-voice
  symptom cannot arise from the driver alone. Audio an app plays *into* them
  stays attributed to that app. Their failure mode is different — selected as
  a mic with nothing feeding them they deliver digital silence, which Part
  C/D's exact-zero detector covers. If a user builds a manual monitoring
  chain (a player app rendering BlackHole's input out loud), the *player* app
  is the one to exclude.
- **SoundSource**: output manager; its processing runs inside each source
  app's process via ACE, so attribution stays with the source app —
  user-addable if a setup proves otherwise.
- **Mute utilities (Mic Drop etc.)**: mute/unmute the input device via HAL
  controls; never in the audio path, no handling needed.
- **Hardware-DSP control apps (Focusrite Control, Vocaster Hub, GoXLR,
  Apogee)**: mixing and direct monitoring happen inside the interface
  hardware; the control app renders no audio, and analog monitoring can
  never reach ScreenCaptureKit.
- **OBS** with mic monitoring enabled shows the router signature and is safe
  to exclude (it is never the source of call audio) — a good candidate for
  users to add when the Part A diagnostic flags it.

Bundle-ID matching is case-insensitive at filter-build time.

**Plumbing:**

- `TranscriptionEngine.start(...)` gains `excludedAudioAppIDs: [String]`;
  ContentView passes `settings.excludedAudioAppIDs`. The engine retains the
  list for the session (alongside `activeRecordingContext`) so
  `restartSystemAudioLeg()` rebuilds with the same filter.
- `SystemAudioCapture.bufferStream(recordingContext:excludedBundleIDs:)`
  unions the passed set with the hardcoded `noiseAppBundleIDs` (which keeps
  its distinct rationale and comment) and builds the same
  `SCContentFilter(display:excludingApplications:exceptingWindows:)`.
  The existing `[SYS-CAPTURE] excluding …` diagLog line reports the full
  merged set — this is the after-the-fact evidence trail for "why was app X
  not captured".
- Settings changes apply at the next session start (no mid-session filter
  rebuild; document in help text).

**Settings UI** (Settings ▸ Audio, new "System Audio" section): the list with
per-row remove, a text field to add a bundle ID, and "Restore Defaults"
(re-seeds `excludedAudioAppIDs` from built-ins without touching user
additions). Help text: one sentence on what routers do to the capture and
that exclusion never affects the mic leg.

**Why list-driven rather than fully generic:** no per-app *code* exists —
the bundle IDs are data feeding one `SCContentFilter` call. Detection of
routers is fully generic (the signature diagnostic below). What cannot be
generic is the *decision* to exclude at recording time: during a live call a
conferencing app carries the identical signature (mic in + audio out), SCK
offers nothing finer than whole-app exclusion, and a wrong automatic
exclusion is silent far-end loss (§6 of the problem statement). Possible v2
refinement without crossing that line: sample the signature at *idle* (no
recording active), when only true routers match, and prompt the user once to
add the app to the list — self-populating, but still confirmed. The fully
generic end-state (device-scoped CoreAudio process taps = "capture what the
user hears", no list at all) is catalogued under Out of scope / future.

**Router-signature diagnostic (warn-only, never auto-exclude):** at session
start, enumerate CoreAudio process objects (the `caprobe` technique — no
TCC) and diagLog any process with `IsRunningInput && IsRunningOutput` that
is not in the exclusion set. This is the acoustic signature of a mic
pass-through router. It must **never** auto-exclude, because conferencing
apps show the same signature during a live call (mic in + far-end out) and
excluding one would silently kill far-end capture — the exact failure §6
warns about. Optional UI: a passive hint in the Settings section when such a
process is running.

### Part B — Content-aware empty-system-leg detection

Delivery-based machinery cannot see this (verified: buffers flow during
total silence), so add content telemetry:

- `SystemAudioCapture`: per-session `_audibleBufferCount`
  (`OSAllocatedUnfairLock<Int>`, reset in `bufferStream`, incremented in
  `didOutputSampleBuffer` when the buffer RMS — already computed for the
  level meter — exceeds **1e-4 (−80 dBFS)**). Threshold rationale: measured
  Wave Link mix noise floor ≈ −99 dBFS RMS; `say` speech ≈ −27; the quiet
  captures' per-buffer RMS (1.1e-5) sits well below 1e-4. Expose
  `audibleBufferCount: Int`.
- **Mid-session one-shot (60s):** in the existing capture watchdog loop
  (`startCaptureWatchdog`), for call captures with the system leg active: if
  elapsed ≥ 60s and `audibleBufferCount == 0`, post one notification per
  session — "No system audio detected yet. If the other side is talking,
  check Settings ▸ Audio ▸ System Audio exclusions." (new
  `NotificationPresenter.postSystemAudioSilent`, modeled on
  `postCaptureStall`). 60s, not the 8s startup-gate window: at 8s the meeting
  simply may not have started; a false alarm on every join would train users
  to ignore it.
- **End-of-session note:** `stopSession()` snapshots `audibleBufferCount`
  into the `SessionHandle`; if 0 for a call capture, the save banner and
  completion notification append "system audio was silent for this session".

This also catches silent-leg failures unrelated to exclusion (permission
revocation mid-session, routing misconfigurations), which today surface only
as an empty `THEM` column.

### Part C — Persist mic selection by device UID

`AudioDeviceID`s are transient (third-party HAL drivers reload, USB replug,
reboot); `ContentView.swift:199` already works around the fallout by
resetting the selection. Replace ID persistence with UID persistence:

- **`AppSettings`:** `inputDeviceUID: String` (`""` = system default) and
  `inputDeviceName: String` (last-known display name, for UI when the device
  is absent). One-time migration in `init`: if legacy `inputDeviceID != 0`,
  resolve via `MicCapture.deviceUID(for:)`/`deviceName(for:)` when the
  device is present (else leave `""`), then remove the legacy key.
- **`MicCapture`:** extend `availableInputDevices()` to
  `[(id: AudioDeviceID, uid: String, name: String)]` (UID via the existing
  `kAudioDevicePropertyDeviceUID` read); add
  `deviceID(forUID:) -> AudioDeviceID?` (enumerate + match).
- **`SettingsView` picker:** selection binds to `inputDeviceUID` (String
  tags). If the persisted UID is not in the current device list, render an
  extra row `"<inputDeviceName> (unavailable)"` tagged with that UID so the
  selection stays visible and intact instead of the picker going empty.
- **`ContentView.swift:199` sanitize block: delete.** Selection is no longer
  reset at boot; an absent device is a UI state, not an error. (This is what
  makes acceptance criterion 5 pass across reboot/replug/router restart.)
- **`TranscriptionEngine`:** `start`/`restartMic` take `inputDeviceUID:
  String` in place of the raw ID. The engine stores `userSelectedDeviceUID`
  and resolves UID → ID **at every bind attempt** (start, restartMic,
  watchdog rebuilds), so a driver reload that changed the numeric ID is
  transparently re-resolved. Unresolvable UID → session falls back to the
  default input **and Part D surfaces it**; `userSelectedDeviceUID` is
  preserved so later rebuild attempts keep aiming at the chosen device
  (matching the existing `updateSelection: false` semantics). The
  default-device CoreAudio listener guard becomes
  `userSelectedDeviceUID.isEmpty`.
- **Bound-but-silent virtual device** (problem statement §9: Wave Link's
  virtual inputs persist in CoreAudio while the app is closed and deliver
  zeros): a real microphone never delivers *exact* digital zeros (self-noise
  floor ≠ 0 — every live capture in verification had non-zero frames), so
  exact-zero output is the signature of an unfed virtual device. `MicCapture`
  tracks whether every frame in the first 5s was exactly 0; the engine then
  posts one warning — "Microphone '<name>' is delivering silence. The app
  that provides it (e.g. Wave Link) may not be running." — and shows the
  Part D banner. No auto-switch: the user picked this device; changing the
  Settings selection mid-session already live-restarts the mic.

### Part D — Surface every mic fallback

The silent fallback at `TranscriptionEngine.swift:679` (and the
UID-unresolvable case added by Part C) becomes visible state:

- New engine observable `activeMicFallback: (selected: String, actual:
  String)?` — set whenever the bound capture device differs from the user's
  selection, including the `silent: true` startup-gate path (the *attempt
  error* stays silent per its rationale; the *resulting fallback state* does
  not). Cleared when a rebuild lands back on the selected device or the
  session ends.
- `ControlBar`: persistent banner (same visual channel as `errorMessage`)
  while non-nil: "Recording from <actual> — selected mic '<selected>'
  unavailable."
- One notification per session:
  `NotificationPresenter.postMicFallback(selected:actual:)` — the Tome
  window is typically hidden behind the meeting app when this matters.

## Acceptance criteria

1. Wave Link running, mic through a Wave Link device, local speech → exactly
   one transcript entry per utterance, attributed to `YOU`. *(Part A;
   mechanism proof: exclusion test = exact digital silence.)*
2. Wave Link running, far-end routed through Wave Link → remote speech still
   captured on the system leg. *(Verified mechanism item 5: source-process
   attribution. Manual confirmation with a real Teams call required at
   implementation — see Test plan.)*
3. Wave Link not running → behavior unchanged. *(Exclusion filters match
   running apps only; with no router running the filter is identical to
   today's.)*
4. **(Revised)** An empty system leg is detected by *content*, not delivery:
   one warning at 60s of a call capture with zero audible buffers, plus an
   end-of-session note. Revision rationale: verified that SCK delivers
   buffers continuously during total silence, so the startup-delivery gate
   window (8s) cannot detect this and would false-alarm on every quiet
   meeting join if made content-aware.
5. Mic selection survives reboot, USB replug, and router-app restart.
   *(Part C: UID persistence + per-bind resolution + no boot reset.)*
6. An unresolvable persisted device, and any session recording off a
   non-selected device, is surfaced via banner + notification, never silent.
   *(Part D; bound-but-silent virtual devices via the exact-zero detector.)*

## Test plan

**Unit (`Tome/Tests/TomeTests`, Swift Testing — extend existing suites):**

- Exclusion-set merge: pure function (user list ∪ `noiseAppBundleIDs`,
  case-insensitive, unknown IDs no-op against a fixture app list).
- `AppSettings` seeding/migration: fresh install seeds defaults; user
  removal survives re-init; new built-in default joins an existing install
  exactly once; legacy `inputDeviceID` → UID migration (resolver injected).
- Audible-buffer accumulator: zero buffers don't count, −80 dBFS+ buffers
  do; reset per session.
- Exact-zero mic detector: all-zero frames for 5s trips it; a single
  non-zero frame arms it off permanently for the session.
- Fallback state: engine predicate-level tests (mirroring
  `shouldForceStartupRestart` style) for set/clear of `activeMicFallback`.

**Manual (on the repro machine, Wave Link installed):**

1. Wave Link running, speak → transcript has `YOU` lines only (AC-1).
2. Real Teams/Meet call with output routed through Wave Link → `THEM`
   populated; **compare "Them" transcription quality vs a Wave Link-quit
   call** — post-fix the far-end is captured at source-process gain, which
   measured ~25 dB below Wave Link's re-render in verification (−52 vs −27
   dBFS for the same signal); confirm VAD+ASR quality is unaffected (AC-2).
3. Quit Wave Link mid-Wave-Link-device selection → mic exact-zero warning
   within ~8s (AC-6 / §9 failure mode).
4. Pin the XLR Dock mic, reboot, replug USB, restart Wave Link → selection
   intact in Settings each time (AC-5).
5. Call capture with a muted remote side for 60s+ → one "no system audio"
   notification, note on save (AC-4).
6. `docs/superpowers/specs/assets/2026-07-24-sckprobe/` harness re-run after
   implementation: `exclude:` spec over the shipped merged set must report
   `nonzeroFrames=0` with Wave Link running and the room quiet.

## Out of scope / future

- **CoreAudio process taps** (`AudioHardwareCreateProcessTap`): device-scoped
  taps could capture "what reaches the physical output device" instead of
  "what every app renders", which models the user's intent more directly and
  would also dedupe the far-end double-capture (mechanism item 6) without a
  list. Larger change (new TCC prompt — `kTCCServiceAudioCapture` instead of
  Screen Recording — plus a rewrite of `SystemAudioCapture`); revisit if the
  exclusion list proves insufficient in the field.
- Transcription/diarization changes — capture-layer defect only.
- Mid-session application of exclusion-list edits.
- Deduping the residual far-end double-capture for *non-excluded* routers
  (mitigated by the same exclusion list).

## Appendix — verification harness

`assets/2026-07-24-sckprobe/` contains both probes, self-contained:

- `sckprobe.swift` — SCK enumeration + filtered audio capture with signal
  statistics (`list` / `capture <seconds> all|exclude:<ids>|only:<id>`).
  Build: `swiftc -O sckprobe.swift -o sckprobe`. Requires Screen Recording
  TCC for the invoking terminal (granted on the repro machine 2026-07-24).
  The discriminator is `nonzeroFrames`: exact digital silence vs any live
  signal — immune to quiet-room ambiguity.
- `caprobe.swift` — TCC-free CoreAudio process-object enumeration
  (`kAudioHardwarePropertyProcessObjectList`): per-process bundle ID,
  IsRunning/Input/Output. This is both the verification tool for
  attribution and the reference implementation for Part A's
  router-signature diagnostic.
