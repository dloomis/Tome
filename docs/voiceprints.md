# Voiceprint speaker enrollment

Goal: stop re-deriving "who is Speaker 2" from transcript text every meeting.
pyannote already computes an acoustic embedding per speaker during diarization;
we surface it, store it as a neutral artifact next to the transcript, and let the
Obsidian side (WhisperCal) bind it to a real person — once — off the speaker-tag
confirmation the user already does.

The signal is acoustic; the binding is human-once-then-automatic; the `Speaker N`
label is just the join key between Tome's artifact and WhisperCal's confirmation.

## Phase 1 — Tome emits anonymous per-speaker voiceprints

After diarization, compute one L2-normalized centroid per diarized speaker
(cleanliness-weighted mean of that cluster's window embeddings) and write a sidecar
next to the finalized transcript. Keys are the **same `Speaker N` labels used in the
transcript body** (`speakerLabels`, encounter order from 2) so they line up with what
WhisperCal's speaker-tag modal shows as `original_name`.

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

- `model` — the embedding-space identity. **Matches are refused across mismatches.**
  Bump whenever the diarization model changes (pyannote v4 → v5, etc.).
- `dimension` — embedding length, derived at runtime (not hard-coded).
- `source` — `system` for phase 1 (the diarized stream is system audio). `mic` /
  `mixed` reserved for the voice-memo and backfill paths so provenance stays explicit.
- `includesYou` — false for phase 1 (you are the un-diarized mic channel, not in this
  artifact). Reserved for voice-memo diarization, where you *are* a diarized speaker.
- `activeSeconds` / `segmentCount` — per-speaker quality signal so the consumer can
  refuse to enroll a flimsy drive-by centroid.

`You` is never written here. Voice memos (no system stream) write no sidecar.
Opt-in: gated behind a single `Settings ▸ Output` toggle (off by default) — these are
biometric vectors, and a classified context needs a clean off switch.

## Phase 2 — WhisperCal binding contract (shapes phase 1, built later)

The bind happens at `SpeakerTagModal` **Apply** — the confirmation the user already
makes. No new manual step. Contract:

1. **Resolve the sidecar** from the transcript: `voiceprints:` frontmatter link, else
   `<stem>.voiceprints.json` sibling. Absent → no enrollment (text-only tagged file).
2. **Reject cross-model** prints: if `sidecar.model` ≠ the library's model, skip the
   whole file. The vectors live in different spaces and must not be compared or merged.
3. **Per confirmed speaker**, key the sidecar by the row's `original_name` (e.g.
   `Speaker 2` — the verbatim transcript label, which WhisperCal already persists in the
   `speakers` frontmatter on Apply). Enroll only when **all** hold:
   - `sidecar.speakers[original_name]` exists,
   - the confirmed name is non-blank,
   - confidence ∈ {CERTAIN, HIGH},
   - the row is **not** flagged mixed (Rule 7 — a catch-all label's centroid is
     contaminated and would poison the person's print),
   - `activeSeconds ≥ minEnrollSeconds` (default 5).
4. **Append a sample** `{ embedding, sourceTranscript, activeSeconds, source, date }`
   to `Caches/Voiceprints/{Confirmed Name}.json` (mirrors `Caches/Speaker Signatures/`).
   Recompute the normalized mean used for matching; cap to the N most-informative
   samples so one bad capture can be pruned rather than baked into the mean.
   One person split across two labels → each label is its own sample (expected; good).

## Phase 3 — matching (pre-LLM, built later)

Before invoking the LLM, for each sidecar speaker compute cosine distance to every
enrolled person's mean. Best ≤ `maxDistance` **and** `(secondBest − best) ≥ minMargin`
→ assign that name, confidence CERTAIN, `source: "voiceprint"` (a new top-priority
"Rule 0" in the tag prompt). Everything unmatched falls through to the existing text
pipeline. Net effect: known attendees tag deterministically, locally, with nothing
leaving the machine; the LLM only handles genuinely unknown voices.

## Sequencing

1. **Phase 1** — system-stream prints going forward (this doc, now).
2. **Backfill** (optional warm-start) — re-diarize the retained mono `.m4a`s, re-align
   clusters to already-tagged transcripts by timestamp overlap, enroll confirmed names.
   Lower quality (mono mix + AAC + your voice + overlap); treat as provisional.
3. **Enroll You** — capture your own print from the clean call-capture mic channel, so
   the voice-memo diarizer can label you acoustically.
4. **Voice-memo diarization** — diarize the mic stream; relabel the single `You` block
   into N speakers (a new rebuild mode), powered by the prints from 1–3.
