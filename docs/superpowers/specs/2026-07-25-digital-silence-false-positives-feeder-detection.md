# Digital-Silence False Positives — Detect the Feeder, Not the Silence

**Date:** 2026-07-25
**Status:** Implemented 2026-07-25 (`FeederDetection.swift`, verdict-routed
checks in `TranscriptionEngine`, `micSilenceHintMessage` hint line in
`ControlBar`; manual AC on the reference machine still owed)
**Type:** Fix (capture diagnostics / usability)
**Prereq reading:** `2026-07-25-mixer-device-system-audio-capture.md` (defines
both digital-silence checks and the reference Wave Link mix setup)

## Problem / Motivation

Usability report (2026-07-25, reference machine): starting a Call Capture
while waiting for participants to join produced a red error banner at 0:08 —

> Elgato Wave Link Mic Only is delivering silence — it may be muted, or the
> app that provides it (e.g. Wave Link) may not be running.

Everything was configured correctly. Wave Link was running, both mixes were
fed, and the silence was *real and expected*: the user was muted and nobody
had joined the call yet. The check cried wolf inside the first ten seconds of
a healthy session.

There are two checks with the same blind spot, and the reference setup
triggers **both**:

1. **Mic leg** (`armMicDigitalSilenceCheck`, +8s). The premise "a real mic's
   noise floor is never exact zeros" is true of an analog capsule but false
   one hop downstream: the mic is pinned to the `Mic Only` **mix**, and Wave
   Link's mute (Stream Deck key, Wave capacitive mute) renders **exact
   digital zeros** into that mix. Being muted at the top of a call is normal,
   deliberate behavior — not a configuration error.

2. **System leg, device mode** (`armSystemDeviceDigitalSilenceCheck`, +5s).
   The spec's premise — "any live channel on a mix bus has a non-zero noise
   floor; exact zeros mean unfed" — only holds when an *analog* channel is in
   the mix. The recommended `Transcriber` mix deliberately contains **only
   app channels** (Teams, Zoom, Chrome…), which emit exact zeros until the
   far end produces sound. Pre-join silence on a call is indistinguishable
   from an unfed mix *by sample content* — the check fires at +5s on every
   session started before the call does.

The root error is epistemic: **silence content can never distinguish "unfed"
from "fed but quiet."** No threshold or longer timer fixes that — a 30s timer
still false-positives on a 40s wait for attendees.

## What the checks are actually for

The real failure mode both checks exist to catch (and must keep catching): a
mixer's virtual devices **stay registered in CoreAudio while the mixer app is
closed**, delivering zeros forever. That condition is directly observable —
not from the samples, but from the process table:

- `MixerLeanInPrompt.runningApplicationBundleIDs()` (NSWorkspace, no
  permissions) — is a known mix-publishing mixer running at all?
- `AudioProcessInspector` (CoreAudio process objects, no TCC) — optionally,
  is that process actively running audio I/O?

Both helpers already ship. The fix is to make the silence checks consult the
feeder instead of guessing from the silence.

## Design

### 1. Feeder verdict (new pure helper)

A pure, testable function — house style, same as `mixerToPromptFor`:

```
enum FeederVerdict { case fed, unfed, unknown }

static func feederVerdict(
    deviceName: String?,           // e.g. "Elgato Wave Link Transcriber"
    runningBundleIDs: [String],
    knownMixers: [String] = MixerLeanInPrompt.mixPublishingMixerBundleIDs
) -> FeederVerdict
```

- Device name matches a known mixer's device-name signature (Wave Link
  devices are all prefixed `Elgato Wave Link `) **and** that mixer's bundle
  ID is running → `.fed`. Zeros are content, not a fault.
- Name matches a known mixer but **no** known mixer bundle ID is running →
  `.unfed`. This is the real failure, now attributed with certainty.
- Name matches nothing we know → `.unknown` (arbitrary virtual devices have
  no owner-process property — HAL plugin devices are owned by `coreaudiod`,
  so name + running-app is the best attribution available).

Ship-only-verified rule applies to the name signatures, same as the bundle-ID
lists: a prefix that never matches is a silent no-op.

### 2. Silence checks route on the verdict

At fire time (zeros confirmed past the deadline), each check evaluates the
verdict instead of unconditionally posting:

| Verdict | System leg (device mode) | Mic leg |
|---|---|---|
| `.fed` | **No banner.** `diagLog` only. Quiet call ≠ fault. | **No red banner.** Neutral, non-error status hint ("Mic is muted or silent"), never `lastError`. |
| `.unfed` | Warn immediately with *sharper* text: "Wave Link isn't running — ⟨device⟩ is registered but unfed." | Same sharpened text. |
| `.unknown` | Current warning, current wording (hedged "may be…"). | Current warning. |

The recovery monitors are unchanged (first nonzero sample clears everything),
but the `.fed` path keeps its monitor armed with a twist: if the feeder app
**quits mid-session** while zeros persist, the verdict flips to `.unfed` on
the next 5s tick and the warning posts then. Re-evaluate the verdict every
tick — it's cheap (one NSWorkspace snapshot) and it's what makes the monitor
catch "Wave Link crashed during the call."

### 3. Bind-time proactive check (the actual feature request)

The report's ask — "a better way to detect if a Call audio source is indeed
detected and configured correctly" — is answerable at **bind time, in zero
seconds**, without waiting for any audio: when `resolveSystemSource` resolves
to a device whose verdict is `.unfed`, surface the warning at session start
rather than 5s in. Same for the mic bind. The silence checks remain as the
backstop for `.unknown` devices and mid-session feeder death.

This inverts the UX: a genuinely broken configuration is reported *sooner*
(0s vs 5–8s), while a healthy quiet session is never flagged at all.

### Non-goals

- No acoustic heuristics (noise-floor thresholds, dither detection). The
  epistemic gap is unbridgeable from samples alone; don't reintroduce it.
- No long-silence "are you still muted?" escalation on the mic leg in this
  spec. Plausible future usability feature, separate decision — it must not
  ride the error channel.
- No change to SCK mode, the delivery gates, or the stall watchdog.

## Testing

`feederVerdict` is pure — table tests over (device name × running-set)
combinations, including case-insensitivity and the unknown-device fallthrough.
The check-routing branches get the same treatment as the existing watchdog
tests: inject running-bundle snapshots, assert which of banner /
notification / diag-only fires per verdict.

Manual AC on the reference machine:
1. Start Call Capture muted, before joining a call, Wave Link running →
   no red banner at any point; neutral mic hint at most.
2. Quit Wave Link, start Call Capture → unfed warning at bind time (0s),
   sharpened wording.
3. Start healthy, quit Wave Link mid-session → warning within ~5s of quit.
4. Unmute / far end speaks → any posted hint or warning clears.
