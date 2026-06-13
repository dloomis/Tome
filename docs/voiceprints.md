# Voiceprint speaker enrollment

Stop re-deriving "who is Speaker 2" from transcript text every meeting. pyannote computes
an acoustic embedding per speaker during diarization; Tome surfaces it as a neutral
artifact next to the transcript, and the Obsidian side (WhisperCal) binds it to a real
person — once — off the speaker-tag confirmation you already make. After that, known
people are tagged by voice, locally, with nothing leaving the machine.

The signal is acoustic; the binding is human-once-then-automatic; the `Speaker N` label is
the join key between Tome's artifact and WhisperCal's confirmation.

**Status: shipped (phases 1–3 + backfill), across two repos:**
- **Tome** — emits the sidecar (`VoiceprintSidecar`) + a diagnostic/backfill CLI
  (`Sources/VoiceprintAudit/`).
- **WhisperCal** — enrollment, matching, and self-heal (`VoiceprintEnroller`,
  `VoiceprintMatcher`).

## The embedding API

Per-speaker centroids come from `DiarizationResult.speakerCentroidEmbeddings` — the
official API added in **argmax-oss-swift** (formerly WhisperKit) by upstream PR #463: an
L2-normalized mean embedding per speaker cluster. `Tome/Package.swift` is pinned to that
commit (unreleased as of pinning); re-pin to a tagged release once it ships in one. The
embedding space is identified by the sidecar's `model` field (`speakerkit-1.0`); consumers
refuse to compare vectors across differing models.

## Phase 1 — Tome emits per-speaker voiceprints

When `AppSettings.exportVoiceprints` is on (Settings ▸ Output, off by default),
`PostProcessingJob` writes a sidecar next to the finalized transcript after diarization.
Keys are the **same `Speaker N` labels used in the transcript body** (`speakerLabels`,
encounter order from 2) so they line up with what WhisperCal's speaker-tag modal shows as
`original_name`.

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
- `source` — `system` (the diarized stream is system audio). `mic` / `mixed` reserved for
  the voice-memo and backfill paths.
- `includesYou` — false (you are the un-diarized mic channel). Reserved for voice-memo
  diarization, where you *are* a diarized speaker.
- `activeSeconds` / `segmentCount` — per-speaker quality signal so the consumer can refuse
  a flimsy drive-by centroid.

`You` is never written here; voice memos (no system stream) write no sidecar. These are
biometric vectors, hence the opt-in toggle.

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

- **Enroll You** — capture your own print from the clean call-capture mic channel.
- **Voice-memo diarization** — diarize the mic stream and relabel the single `You` block
  into N speakers, powered by the enrolled prints.
