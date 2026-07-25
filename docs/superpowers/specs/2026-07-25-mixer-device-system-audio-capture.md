# Mixer-Device System-Audio Capture — "Lean-In" Mode for Audio Routers

**Date:** 2026-07-25 (revised same day after design review — exclusion-list
demotion, no-forced-mode decision, MacWhisper API survey)
**Status:** Proposed — ready to implement
**Type:** Feature (capture layer)
**Prereq reading:** `2026-07-24-own-voice-bleed-audio-router-exclusion.md` (the
exclusion workaround this feature makes optional; its verified-mechanism
section is assumed knowledge here)

## Problem / Motivation

Tome's system-audio ("Them") leg captures **every process's rendered audio**
via ScreenCaptureKit and then subtracts what shouldn't be there: hardcoded
media players plus the audio-router exclusion list shipped 2026-07-24. That
workaround is correct but adversarial — when a user runs a professional mixer
(Elgato Wave Link, Loopback, RØDE UNIFY, …), Tome treats the mixer's output
as contamination to be filtered out.

Mixers have a *blessed* consumption model that Tome currently ignores: they
publish their mixes as **virtual CoreAudio input devices**, and consuming
apps (OBS, streaming tools) subscribe to a mix by selecting that device as an
input. A mixer user can build a mix containing exactly the call audio —
their own mic channel muted, music muted — and hand Tome a cleaner "Them"
feed than SCK can ever assemble:

- No own-voice bleed *by construction* (the mic channel isn't in the mix),
  instead of by per-app exclusion.
- Per-channel curation: music/notification audio never reaches VAD+ASR,
  instead of the coarse `noiseAppBundleIDs` list.
- No Screen Recording permission needed for the session — input-device
  capture rides the mic TCC grant Tome already holds.
- The residual far-end double-capture for non-excluded routers (verified
  mechanism item 6 in the 2026-07-24 spec) cannot occur — there is exactly
  one capture path.

This spec adds an opt-in capture source for the system leg: **a
user-selected audio input device** in place of ScreenCaptureKit. The default
(SCK + exclusions) is unchanged and remains correct for the ~80% of installs
with no mixer.

### Reference setup (verified on this machine, 2026-07-25)

Wave Link (3.x) publishes each mix as a virtual input device named after the
mix. The reference configuration this spec was designed against:

| Wave Link mix | Virtual device (CoreAudio) | Contents |
|---|---|---|
| Headphones | `Elgato Wave Link Headphones` | what the user hears (monitor) |
| Transcriber | `Elgato Wave Link Transcriber` | "All audio" channel only; **XLR Dock mic channel not routed** |
| Mic Only | `Elgato Wave Link Mic Only` | XLR Dock mic only (current system default input) |

Target Tome configuration (user decision 2026-07-25): mic leg **pinned by
UID** to `Mic Only` via the existing mic picker (pinned, not system-default,
so a macOS default-input reassignment — e.g. AirPods connecting — can never
move a recording mid-session), system leg = `Transcriber` (this feature).
The Transcriber mix is fed by dedicated per-app channels (Teams, Zoom,
Mattermost, Chrome) rather than the catch-all "All audio" channel, so
music/notification audio never reaches the transcript; those app channels
must ALSO be routed to the Headphones mix or calls become inaudible to the
user (a Wave Link-side footgun observed during setup — creating a dedicated
channel removes that app from "All audio"). All Wave
Link virtual devices report 48 kHz / 2ch, `Transport: Virtual`, manufacturer
"Corsair Memory, Inc.".

## Design

Four parts. A is the capture mode; B is settings + UI (including the
exclusion-list demotion and the no-forced-mode decision); C is telemetry/
failure-surfacing parity; D is the guided discovery prompt.

### Part A — Device-backed system leg via a second `MicCapture`

**Decision: reuse `MicCapture` for the device-backed system leg** (a second
instance owned by the engine), rather than writing a new capture class or
extending `SystemAudioCapture`. Everything the system leg needs already
exists in `MicCapture`, battle-hardened by the AirPods/HAL incidents:

- device binding by ID (`kAudioOutputUnitProperty_CurrentDevice`) with
  errors surfaced via `captureError` instead of silent fallback;
- crash-safe WAV retention (`WAVStreamWriter`, header refreshed per write)
  with **append-reopen on mid-session rebuild** (`_establishedFormat`) — a
  device restart preserves the already-captured audio, which is behavior the
  SCK leg's writer doesn't need but a device leg does;
- HAL fast-path property listener + `AVAudioEngineConfigurationChange`
  rebuild hook — exactly what a virtual device disappearing (mixer app
  quit/relaunch) produces;
- `firstSampleTime` / `lastSampleTime` / `captureStartTime` — the fields the
  watchdog, startup gate, and post-session mixer alignment consume;
- `sawNonzeroSample` — the unfed-virtual-device detector, which is *more*
  load-bearing here: an unfed mix device is this mode's primary failure
  state (Wave Link closed, mix deleted);
- mono downmix (the stereo mix device → the mono pipeline).

**`MicCapture` additions (both small, benefit the mic leg too):**

1. `audibleBufferCount: Int` — per-`bufferStream` counter of buffers with
   RMS > `SystemAudioCapture.audibleRMSThreshold` (1e-4), incremented in the
   tap where RMS is already computed, reset on each `bufferStream` entry.
   Gives the device leg the same content-aware silence telemetry as the SCK
   leg (Part B of the 2026-07-24 spec).
2. `writeErrorCount: Int` — count of retention-WAV write failures (the tap
   currently `try?`-swallows them), reset per `bufferStream`. Seeds
   `SessionHandle.wavWriteErrorCount` in device mode with real data instead
   of a hardcoded 0.

**`TranscriptionEngine`:**

- New member `systemDeviceCapture = MicCapture()` alongside the existing
  `systemCapture = SystemAudioCapture()`. Two `AVAudioEngine` input captures
  on different devices is supported (each engine binds its own HAL unit);
  the `retire()` deallocation guard applies per instance.
- New session state `activeSystemSourceUID: String` (retained at `start()`
  like `activeExcludedAudioAppIDs`, so gate/watchdog rebuilds re-aim at it)
  and `systemSourceMode: enum { sck, device(AudioDeviceID) }` resolved per
  bind.
- `start(...)` gains `systemAudioSourceUID: String = ""`. Resolution, only
  reached when `captureSystemAudio == true`:
  - `""` → SCK path, byte-for-byte today's behavior.
  - Non-empty, `MicCapture.deviceID(forUID:)` resolves → **device mode**:
    - `currentBufferURL` = the same `sessions/<sessionId>.wav` path the SCK
      path uses (so `PostProcessingJob`, retention mixing, and
      `cleanupBufferFile` are unchanged).
    - Engine emits `SessionSidecar.emit(forWAV:context:sampleRate:)` before
      starting capture — the SCK path emits its sidecar inside
      `SystemAudioCapture.bufferStream`; device mode mirrors the existing
      mic-only-session sidecar emission in `start()` (nominal rate; recovery
      reads the WAV header).
    - `systemDeviceCapture.bufferStream(deviceID: id, recordOutputURL:
      currentBufferURL)` → the returned `AsyncStream` feeds the existing
      `spinUpSystemTranscription(stream:vadManager:)` unchanged.
    - A synchronous `captureError` from the bind fails **the leg, not the
      session** — matching today's SCK-bring-up-failure behavior (`lastError`
      set, mic leg continues), then falls back per below.
  - Non-empty, unresolvable (device absent) → **fall back to SCK for this
    bind** and surface it (Part C). `activeSystemSourceUID` is preserved;
    every rebuild re-resolves and returns to the device when it reappears —
    the same semantics Part C of the 2026-07-24 spec gave the mic UID.
- **Rebuild paths** (`restartSystemAudioLeg`, armed by the system startup
  gate and the watchdog): branch on the re-resolved mode. Device-mode
  rebuild re-enters `systemDeviceCapture.bufferStream` with the SAME
  `recordOutputURL` — the append-reopen path keeps the session WAV intact.
  `systemDeviceCapture.onConfigurationChange` schedules the same debounced
  rebuild (new `scheduleSystemDeviceRebuild`, mirroring `scheduleMicRebuild`
  including the rebuild-storm cap and ground-truth gate).
- **Accessor routing:** `systemAudioAudibleBufferCount`,
  `systemAudioWriteErrorCount`, `systemFirstSampleTime`, and the watchdog's
  `lastSampleTime` read branch on `systemSourceMode`. `stop()` stops
  whichever source is active (stopping both is harmless and simpler).
- **Suppressed in device mode:**
  - The `AudioProcessInspector.micPassthroughBundleIDs` warn-log — a running
    router is *expected*; it is the source.
  - The exclusion list — `SCContentFilter` is never built. (The list is
    data, not behavior, in this mode; it stays configured for automatic
    sessions.)
- **Guard:** if the resolved system-source device ID equals the resolved mic
  device ID, refuse device mode for the session (fall back to SCK + Part C
  surfacing). Capturing the same device on both legs guarantees every
  utterance transcribes twice — the exact defect this feature exists to
  prevent. Settings also warns at selection time (Part B), but the engine
  guard is the invariant: settings races (mic changed after source was
  picked) must not produce a double-capture session.

**What is deliberately NOT changed:** `SystemAudioCapture` (untouched),
`StreamingTranscriber` (already consumes arbitrary-rate mono buffers from
the mic leg), `PostProcessingJob` / diarization / voiceprints (the system
WAV keeps its path, stem-pairing, and `source: "system"` meaning — a
Transcriber-mix WAV is still "the not-You stream"), `TranscriptFinalizer`,
API server.

### Part B — Settings + UI

**`AppSettings`** (UserDefaults-backed, mirroring the mic-selection pair):

- `systemAudioSourceUID: String` — `""` = "System audio (automatic)", i.e.
  today's SCK capture. Key `systemAudioSourceUID`.
- `systemAudioSourceName: String` — last-known display name for the
  unavailable-device row. Key `systemAudioSourceName`.

Scope: **call captures only**. Voice memos have no system leg
(`captureSystemAudio: false`) and are unaffected. `ContentView` passes
`settings.systemAudioSourceUID` into `engine.start(...)` alongside the
existing settings, and changes apply at next session start (same rule as the
exclusion list).

**Settings ▸ Audio ▸ System Audio** (existing section, reworked):

- Top: `Picker("Call audio source")` — first item "System audio (automatic)"
  tagged `""`, then all `MicCapture.availableInputDevices()` tagged by UID,
  plus the `"<name> (unavailable)"` row when the persisted UID is absent
  (same pattern as the mic picker at `SettingsView.swift:115`).
- Inline warning (not a blocker) when the selection equals
  `settings.inputDeviceUID`: "This is your microphone device — Tome would
  hear you twice. Pick a mix that excludes your mic."
- **The exclusion-list UI is removed** (rows, add field, Restore Defaults —
  the whole editable list from the 2026-07-24 Part A UI). See "Exclusion
  list demoted" below; the source picker takes the section's place.
- Help text (the lean-in contract, one short paragraph): create a mix in
  your mixer containing the call/app audio **with your own mic channel
  muted**, then select its virtual device here. Mention QuickTime as the
  quick verification (record from the device; your voice must be absent).
  Second sentence: switch back to "System audio (automatic)" when the mixer
  app isn't running — mixer virtual devices **stay registered in CoreAudio
  while their app is closed and deliver pure silence** (the 2026-07-24 §9
  behavior), so Tome cannot infer "mixer gone" from the device list; a
  forgotten flip is caught by the silence detection in Part C, not by
  automatic fallback (see Out of scope for the planned refinement).

**Exclusion list demoted to an internal detail of automatic mode**
(2026-07-25 design review). The router-exclusion *behavior* is unchanged —
automatic mode still builds its `SCContentFilter` from
`SystemAudioCapture.exclusionBundleIDs(userList:)` — but it stops being a
user-facing concept:

- `AppSettings.excludedAudioAppIDs` + `excludedAudioAppSeenDefaults` keep
  their storage, seeding, and migration exactly as shipped (no data churn;
  prior user additions keep working; a power-user escape hatch remains via
  `defaults write com.dloomis.tome excludedAudioAppIDs -array ...`).
- The Settings UI for the list is deleted. The System Audio section's whole
  surface is the source picker + help text.
- Rationale (recorded so a future session doesn't re-litigate): the
  exclusion list is **already inert in device mode** — it only executes in
  automatic mode, where it is the correctness rule that makes the default
  path safe on a machine where a router happens to be running (mixer
  launched at login but Tome not yet configured; effects apps like Krisp
  that never have a mix to subscribe to; the v2 auto-fallback landing an
  SCK session while the mixer is up). Removing the *behavior* would convert
  a configuration gap into silent duplicate transcription. Removing the
  *UI* costs nothing because exclusion requires no per-user decisions when
  device mode exists for the users who'd otherwise tune it.

**No forced device mode** (2026-07-25 design review). When a router is
detected, Tome must never require the user to pick a device before
recording. Grounds: (a) forcing needs router *detection*, and the acoustic
signature (mic-in + audio-out process) matches every conferencing app
mid-call — a hard gate would misfire on plain Teams users; (b) much of the
router category (Krisp, Voicemod, G HUB) publishes no consumable mix — those
users would be blocked with nothing valid to select; (c) a mixer owner's
usable mix may not exist yet — forcing turns first-record into a mixer
configuration project; (d) exclusion-protected automatic is *verified
correct* with a router running (far-end survives exclusion, 2026-07-24 item
5) — suboptimal is not broken, and a forced gate must be right 100% of the
time while a safe default only has to be safe. Part D's prompt is the
ceiling of steering.

### Part C — Telemetry & failure-surfacing parity

Every guardrail the SCK leg has must exist in device mode, because device
mode trades process-attribution failure modes for configuration failure
modes:

1. **Source fallback surfacing** (new observable
   `systemSourceFallbackMessage: String?`, rendered like
   `micFallbackMessage`): set when a session binds SCK while a device UID is
   configured (unresolvable, bind error, or same-as-mic guard), plus one
   notification per session (`NotificationPresenter.postSystemSourceFallback`,
   modeled on the mic-fallback notification). Cleared when a rebuild lands
   back on the device or the session ends. Never silent — a session
   recording from the "wrong" source is the 2026-07-24 Part D lesson.
2. **Unfed-device detection:** arm a system-leg digital-silence check
   (mirroring `armMicDigitalSilenceCheck`, reading
   `systemDeviceCapture.sawNonzeroSample`): if the first 5s deliver only
   exact zeros — "Call audio device '<name>' is delivering silence. The app
   that provides it (e.g. Wave Link) may not be running, or the mix may be
   empty." A mixer's mix bus with any live channel has a non-zero noise
   floor; exact zeros mean unfed.
3. **60s no-audible warning + end-of-session note:** already keyed on
   `audibleBufferCount == 0` via the engine accessor, which Part A routes to
   the active source — the checks work unmodified. Make the notification
   text mode-aware: device mode says "check your mixer's mix routing"
   instead of "check exclusion settings".
4. **Stall watchdog + startup delivery gate:** work unmodified via the
   routed `lastSampleTime` / rebuild path. Note the semantics quietly
   improve: unlike SCStream, an AVAudioEngine tap on a dead device stops
   delivering, so the watchdog can actually see a dead device leg.

### Part D — Guided discovery prompt (the on-ramp)

With the exclusion UI gone, this is the only place mixer users learn the
lean-in mode exists, so it is a one-time guided prompt rather than a
passive settings hint. Trigger: source is automatic AND a **known
mix-publishing mixer** is running (bundle-ID match against a new internal
constant `mixPublishingMixerBundleIDs` — the subset of the exclusion
built-ins that actually publish consumable mix devices: the two Elgato Wave
Link IDs today; Loopback/RØDE-class apps join only when their IDs are
verified, same ship-only-verified rule as 2026-07-24). Never the acoustic
signature alone — it matches conferencing apps mid-call.

- Surface: a dismissable banner/prompt at app launch or Settings-open (not
  mid-recording): "Wave Link detected. Tome can capture one of its mixes
  directly for cleaner call audio." → button opens Settings ▸ Audio with
  the source picker focused.
- One-shot per install (`UserDefaults` latch, e.g.
  `mixerLeanInPromptShown`), re-armed only if a *different* mixer bundle ID
  appears later.
- Detection by running-application list (`NSWorkspace` or the existing
  `AudioProcessInspector` enumeration) — no new permissions.
- Invitation only. No auto-switch, no gating (see "No forced device mode").
  Automatic mode remains fully correct for users who dismiss it.

## Acceptance criteria

1. `systemAudioSourceUID = ""` → behavior byte-identical to today (SCK,
   exclusions, all existing telemetry). The default ships as `""`.
2. Device mode with the reference Transcriber mix: local speech during a
   call produces exactly one transcript entry (`YOU`); far-end/browser audio
   produces `THEM` entries; diarization, retention mixing, and voiceprints
   produce the same artifacts as an SCK session.
3. A device-mode session never triggers a Screen Recording permission
   prompt.
4. Configured device absent at start → session records with SCK, banner +
   notification say so; when the device returns, the next rebuild (or next
   session) uses it. Nothing is ever silent.
5. Mixer app quits mid-session → silence detection fires within ~5s
   (exact-zero) and/or the watchdog rebuild path runs; the session WAV
   retains all pre-quit audio (append-reopen); the session completes
   normally at stop.
6. System source set to the mic's own device → session runs in SCK mode
   with fallback surfacing; no double transcription.
7. Voice memos are unaffected by any value of `systemAudioSourceUID`.
8. The Settings exclusion-list UI is gone, while automatic mode's exclusion
   *behavior* is unchanged — the 2026-07-24 harness check (sckprobe
   `exclude:` over the merged set, Wave Link running, quiet room) still
   reports `nonzeroFrames=0`, and stored user additions to
   `excludedAudioAppIDs` still take effect.
9. With Wave Link running and the source automatic, the guided prompt
   appears exactly once, routes to the source picker, and never blocks or
   delays recording; it does not appear when the source is already a
   device, when no known mixer is running, or on subsequent launches after
   dismissal.

## Test plan

**Unit (`Tome/Tests/TomeTests`, Swift Testing — extend existing suites):**

- Settings: persistence round-trip of `systemAudioSourceUID`/`Name`;
  defaults to `""` on fresh install; no interaction with exclusion seeding.
- Pure source-resolution function (extract as a `nonisolated static` on the
  engine, injected resolvers, mirroring `migratedInputSelection` style):
  (uid, resolvedID?, micID) → {sck, device, sckFallback(reason)} covering
  empty / resolvable / unresolvable / equals-mic.
- `MicCapture.audibleBufferCount`: zero/sub-threshold buffers don't count,
  ≥1e-4 RMS buffers do, reset on `bufferStream` re-entry (testable at the
  RMS-accumulator level like the SCK counter's tests).
- `MicCapture.writeErrorCount` reset + increment.
- Fallback-message predicate tests (set on sckFallback, cleared on device
  bind / session end), mirroring the `micFallbackMessage` tests.
- Mode-aware notification text selection.
- Prompt latch: pure function over (running bundle IDs, source setting,
  shown-latch) → show/skip; one-shot; re-arms for a not-previously-seen
  mixer ID; never fires when source is a device.
- Existing exclusion seeding/merge tests are RETAINED unchanged — the
  storage and filter behavior ship on; only the UI is removed.

**Manual (repro machine, Wave Link with the reference mixes):**

1. AC-2 end-to-end: real Teams/Meet call, source = `Elgato Wave Link
   Transcriber`, compare transcript vs an automatic-mode call. Check "Them"
   ASR quality — the mix is delivered at mix-bus gain, which should be
   *higher* than the source-process gain SCK gets post-exclusion (−52 dBFS
   observed); confirm level meter and VAD behave.
2. Quit Wave Link mid-session (AC-5): warning within ~5s, WAV intact,
   session finalizes.
3. Unplug/replug + reboot with the source configured (AC-4): fallback
   banner when absent, device re-adopted when present.
4. Select the mic device as source (AC-6): banner, single transcription.
5. Voice memo with a device source configured (AC-7).
6. Spotify playing during a device-mode call: music absent from transcript
   when the mix carries only the conferencing channel — the per-channel
   curation payoff.
7. AC-8 harness re-run (sckprobe `exclude:` spec) after the Settings UI
   removal.
8. AC-9 prompt flow: fresh-latch launch with Wave Link running → prompt →
   Settings; relaunch → no prompt.

## Out of scope / future

- **Wave Link WebSocket integration** (local JSON-RPC used by the Stream
  Deck plugin): mix/channel names in Tome's UI, validation that the captured
  mix has the mic channel muted, one-click "create a Tome mix". The natural
  v2 — but it's an undocumented vendor API, and the neutral device picker
  must stand alone first (tool-agnostic core, opt-in integrations).
- Automatic mode switching (router detected → device mode). Violates the
  never-auto-switch rule; Part D's hint is the ceiling.
- **Session-start auto-fallback on a dead device** (v2, likely the first
  follow-up): because mixer virtual devices persist while their app is
  closed, the absent-device SCK fallback (Part A) will rarely fire for Wave
  Link — the realistic forgotten state is "device present, delivering exact
  zeros," which v1 only warns about. The refinement: probe the configured
  device for ~1s at session start; if every frame is exactly zero, bind SCK
  for the session instead, with the same Part C fallback surfacing. This
  collapses the user's two-state workflow (flip the source when quitting
  the mixer) into "just hit record." Deferred from v1 deliberately:
  warn-don't-switch first, and the probe adds ~1s to call-capture start for
  every device-mode user — measure whether the forgotten-flip warning
  actually occurs in practice before paying that. Mid-session auto-switch
  stays forbidden regardless (a mix that goes quiet because the far end is
  quiet is indistinguishable from a dead one).
- Acoustic own-voice bleed detection (mic↔system cross-correlation) to catch
  a misconfigured mix that still contains the user's mic. Today's guards:
  selection-time warning, same-device refusal, and the duplicate-YOU symptom
  being immediately visible in the live transcript.
- Per-channel multi-track capture (one device per speaker/app). No mixer
  exposes per-channel virtual devices today; diarization keeps that job.
- API-server override of the source per session (joins the tunables-over-
  REST backlog).
- CoreAudio process taps as an SCK replacement for **automatic** mode —
  orthogonal, still catalogued in the 2026-07-24 spec.

## Appendix — environment verified against

- macOS 26.5, Wave Link 3.x, Wave XLR Dock MK.2 + MV7+.
- `system_profiler SPAudioDataType` (2026-07-25): Wave Link publishes
  `Elgato Wave Link Headphones` / `Mic Only` / `Transcriber` as 48 kHz
  stereo virtual input devices; renaming a mix renames its device. Mixes
  bound only to physical outputs are monitor-only; every mix is
  simultaneously available as a virtual input regardless of its "Audio
  output" assignment.
- The 2026-07-24 `sckprobe`/`caprobe` harness
  (`assets/2026-07-24-sckprobe/`) remains the reference for the SCK-side
  behavior this mode bypasses.

### Competitive survey — MacWhisper (binary inspection, 2026-07-25)

MacWhisper 14.4.1 (`RecordKit.framework`) inspected on this machine via
`otool`/`nm`/Info.plist. Findings, recorded because they informed the
design review:

- It captures system audio with **CoreAudio process taps**
  (`AudioHardwareCreateProcessTap`, `CATapDescription`,
  `AudioHardwareCreateAggregateDevice`; TCC = `NSAudioCaptureUsageDescription`,
  i.e. the "System Audio Recording" prompt, not Screen Recording). SCK is
  linked as a secondary path. This validates process taps as the eventual
  SCK successor for Tome's automatic mode (already in Out of scope).
- Imported tap shapes: `mixdownOfProcesses([pids])` (include-list) and
  `globalTapButExcludeProcesses([pids])` (global minus a list), plus a
  `processResolver` in their tap constructor (app → PID-tree resolution).
- **Process taps share SCK's attribution model** — audio belongs to the
  rendering process — so a global tap on a Wave Link machine re-captures
  the mixer's mix exactly like SCK does. MacWhisper has no exclusion list
  because its primary flow include-scopes a chosen app (which excludes
  routers by construction, at the price of the silent-far-end-loss risk
  Tome rejected on 2026-07-10), and its system-wide mode simply does not
  handle the mixer case. No competitor has the lean-in/device-subscribe
  mode; subscribing to the mixer's mix remains the only approach where
  bleed is impossible by construction rather than by filtering.
