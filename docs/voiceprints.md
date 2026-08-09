# Voiceprint speaker enrollment

Stop re-deriving "who is Speaker 2" from transcript text every meeting. pyannote computes
an acoustic embedding per speaker during diarization; Tome surfaces it as a neutral
artifact next to the transcript, and the Obsidian side (WhisperCal) binds it to a real
person — once — off the speaker-tag confirmation you already make. After that, known
people are tagged by voice, locally, with nothing leaving the machine.

The signal is acoustic; the binding is human-once-then-automatic; the `Speaker N` label is
the join key between Tome's artifact and WhisperCal's confirmation.

**Status: shipped (phases 1–3 + backfill + mic/in-person diarization), across two repos:**
- **Tome** — emits the sidecar (`VoiceprintSidecar`) for both call-capture (system stream)
  and mic-only in-person sessions, plus a diagnostic/backfill CLI (`Sources/VoiceprintAudit/`).
- **WhisperCal** — enrollment, matching, and self-heal (`VoiceprintEnroller`,
  `VoiceprintMatcher`).

## The embedding API

Per-speaker centroids come from `DiarizationResult.speakerCentroidEmbeddings` — the
official API added in **argmax-oss-swift** (formerly WhisperKit) by upstream PR #463: a
mean embedding per speaker cluster, returned in the raw embedder space (un-normalized).
Tome L2-normalizes each centroid in `VoiceprintSidecar.build` before writing, so the stored
print is unit-length and matches the backfill CLI's output. `Tome/Package.swift` is pinned to
that commit (unreleased as of pinning); re-pin to a tagged release once it ships in one. The
embedding space is identified by the sidecar's `model` field (`speakerkit-1.0`); consumers
refuse to compare vectors across differing models.

## Phase 1 — Tome emits per-speaker voiceprints

When `AppSettings.exportVoiceprints` is on (Settings ▸ Output, off by default),
`PostProcessingJob` writes a sidecar next to the finalized transcript after diarization.
Which stream is diarized depends on the session:

- **Call capture** diarizes the **system ("them")** WAV; the live mic track stays "You",
  the implicit Speaker 1 excluded from diarization. → `source: "system"`,
  `includesYou: false`, labels numbered from **2**.
- **Voice memo / in-person meeting** is mic-only (no system capture), so it diarizes the
  **mic** WAV itself — every speaker, including the recording user, comes from the diarizer.
  → `source: "mic"`, `includesYou: true`, labels numbered from **1**. A solo memo (≤1
  detected speaker) keeps its "You" transcript and writes no sidecar.
- **Imported WAV** (File ▸ Import) diarizes like a voice memo, but the audio was recorded
  on some other device, so Tome cannot attest the user is among the speakers.
  → `source: "imported"`, `includesYou: false`, labels numbered from **1**.

Keys are the **same `Speaker N` labels used in the transcript body** (`speakerLabels`, in
encounter order from the per-session base) so they line up with what WhisperCal's
speaker-tag modal shows as `original_name`. The orphaned-WAV recovery path (`Recovery.run`,
used when a crash skipped post-processing) emits the same sidecar for the
call-capture/system stream; mic-only crash recovery is not yet wired (the orphan scanner
skips `.mic.wav` companions).

Sidecar — `<transcript-stem>.voiceprints.json`, also referenced by a `voiceprints:`
frontmatter key so the link survives a later rename:

```json
{
  "schema": 1,
  "model": "speakerkit-1.0",
  "dimension": 256,
  "source": "system",
  "includesYou": false,
  "speakers": {
    "Speaker 2": { "embedding": [/* dimension floats */], "activeSeconds": 92.3, "segmentCount": 14 },
    "Speaker 3": { "embedding": [/* ... */], "activeSeconds": 8.1, "segmentCount": 2 }
  }
}
```

- `model` — embedding-space identity; matches are refused across mismatches. Bump when the
  diarization model changes.
- `source` — which stream was diarized: `system` (call capture), `mic` (voice memo /
  in-person meeting recorded live on this machine), `imported` (a WAV brought in through
  File ▸ Import — audio recorded on some other device), or `mixed` (the backfill CLI
  re-diarizing a retained mono mix). Invariant: `source: "mic"` always implies
  `includesYou: true`; consumers deciding whether the recording user is among the prints
  must key on `includesYou`, never on `source` alone.
- `includesYou` — `false` when the recording user is the un-diarized mic channel (call
  capture) or when Tome cannot attest the user is present at all (imported audio);
  `true` for a live mic-only session, where you *are* one of the diarized speakers
  (Tome doesn't label which — WhisperCal binds it on confirmation, learning your own print).
- `activeSeconds` / `segmentCount` — per-speaker quality signal so the consumer can refuse
  a flimsy drive-by centroid.

For call capture, `You` is never written here (it's the un-diarized mic channel); for a
mic-only session the user *is* one of the `Speaker N` prints, just not labeled as such. A
solo voice memo (≤1 speaker) writes no sidecar. These are biometric vectors, hence the
opt-in toggle.

## Phase 2 — WhisperCal enrollment (on Apply)

The bind happens at `SpeakerTagModal` **Apply** — the confirmation you already make, no new
step (`VoiceprintEnroller.enrollVoiceprints`). For each confirmed speaker it resolves the
sidecar (`voiceprints:` frontmatter, else the sibling), keys it by the row's
`original_name` (e.g. `Speaker 2`), and appends a sample to
`Caches/Voiceprints/<Name>.json`. Gates: a non-blank confirmed name, matching `model`, and
`activeSeconds ≥ 5`. **The human confirmation is the trust signal, not the LLM's
confidence** — a name you *corrected* is the most reliable label of all. An outlier guard
skips a sample that looks nothing like the person's existing voice (an obvious
mis-confirmation). Dedupes by source+label; caps at 12 samples (longest-speech win).

## Phase 3 — embeddings-first matching + self-heal

`doTagSpeakers` is embeddings-first (`VoiceprintMatcher.matchVoiceprints`): build the
speaker list, match each sidecar centroid against the enrolled library means
(cosine ≥ threshold **and** a margin over the runner-up), and pre-fill confident hits as
CERTAIN. **Default is LLM-free** — known people are tagged acoustically, unknowns confirmed
by ear in the modal; the LLM runs only as a fallback for unmatched speakers when
`llmSpeakerTagFallback` is on. Self-heal: if you override a voiceprint match, the culprit
sample is removed from the wrongly-matched person's library (gated to outlier-poison so two
similar voices don't cost a legit sample).

## Backfill — `VoiceprintAudit` CLI

`Sources/VoiceprintAudit/main.swift` is a standalone executable target (not part of the
app). Given the retained `.m4a`s, it re-diarizes each mono mix, maps clusters to the
transcript's confirmed names, and:

- **audits** labels via acoustic nearest-neighbour across meetings — flagging likely
  mislabels and name-variant duplicates (run without `--enroll`);
- with **`--enroll <folder>`**, writes the per-person libraries (same schema as the live
  enroller), applying nickname aliases and **excluding audit-flagged suspects** so poison
  never enters.

```bash
swift run VoiceprintAudit [--enroll <Caches/Voiceprints folder>] "<m4a>" ["<m4a>" ...]
```

## What's left

- **Enroll You** — capture your own print from the clean call-capture mic channel. (Mic-only
  in-person sessions already include your print among the `Speaker N` prints — just not
  labeled as yours.)
- **Mic-only crash recovery** — `OrphanScanner` skips `.mic.wav` files and `Recovery`
  assumes a system stream, so an in-person session that crashed before post-processing
  isn't offered for recovery.
