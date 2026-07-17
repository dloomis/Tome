# Session GUID — Tome side design

**Status:** Implemented (Tome side, 2026-07-17). Counterpart doc: `../WhisperCal/SESSION_GUID_DESIGN.md` (the protocol is additive so old WhisperCal builds are unaffected). Tests: `Tome/Tests/TomeTests/SessionGuidTests.swift`.

## Problem

WhisperCal-initiated recordings have no correlation key. `POST /start` generates an internal `sessionId` but returns bare `{"ok":true}` (`APIServer.swift:471`); the WhisperCal `GET /status` is a single global state with no id; the transcript and voiceprint sidecar carry no session identifier; and `MeetingContext.calendarEventId` is decoded then dropped. WhisperCal is left matching finished transcripts by filename prefix + newest-file scans, which is ambiguous exactly in the supported concurrent case: a prior session post-processing (commit `3f45bd0`) while a new one records back-to-back.

The internal `sessionId` (`SessionStore.generateSessionId()`, `SessionStore.swift:25-29`) cannot serve as the correlation key: it is a second-granular timestamp string, documented as reusable/collidable (`SessionStore.swift:35-38`, `PostProcessingQueue.swift:26-30`).

## Solution overview

Every session carries a **session GUID** — supplied by the API caller when present, minted by Tome otherwise — threaded from start through capture, post-processing, and into every output artifact, and queryable per-session over HTTP.

Decisions already made (do not re-litigate):

1. **The initiator generates the GUID.** WhisperCal sends one in `POST /start`; Tome echoes it. Tome mints its own for every session started without one (menu-bar recordings, voice memos, `POST /sessions/start` without a guid) so the field is uniformly present in all artifacts.
2. The GUID **supplements** the internal `sessionId`; it does not replace it. File stems in Application Support, JSONL naming, orphan scanning — all unchanged.
3. WhisperCal keeps its legacy filename matching as a fallback, so Tome-side changes must be strictly additive (old WhisperCal against new Tome must behave exactly as today).

---

## Shared protocol (must match WhisperCal doc verbatim)

**GUID format:** UUIDv4, lowercase, canonical hyphenated form. WhisperCal: `crypto.randomUUID()`. Tome: `UUID().uuidString.lowercased()`.

**Canonical field names:** `sessionGuid` in all JSON (API payloads, voiceprint sidecar); `session_guid` in all Markdown frontmatter (transcript; WhisperCal also stamps it on the meeting note).

### `POST /start` request (additive)

```jsonc
{
  "sessionGuid": "3f1c9e2a-8b4d-4c6e-9f0a-2d7b5e8c1a4f",   // NEW, optional — mint if absent
  "suggestedFilename": "2026-07-17 0930 - Standup - Transcript",
  "meetingContext": { "subject": "…", "attendees": ["…"], "calendarEventId": "…", "startTime": "…" }
}
```

Validation: accept any non-empty string ≤ 64 chars as a guid (don't hard-reject non-UUID shapes); mint when absent/empty.

### `POST /start` response (was bare `{"ok":true}`)

```jsonc
{ "ok": true, "sessionGuid": "3f1c…", "sessionId": "session_2026-07-17_09-30-01" }
```

### `GET /sessions/by-guid/{guid}/status` (new)

```jsonc
// 200
{
  "sessionGuid": "3f1c…",
  "sessionId": "session_2026-07-17_09-30-01",
  "state": "recording" | "transcribing" | "complete" | "failed",
  "startedAt": "2026-07-17T09:30:01-04:00",        // present while recording
  "transcriptFilename": "Standup - Transcript.md",   // when complete — FINAL basename after collision -1/-2 suffixes and renames
  "transcriptPath": "/Users/dloomis/Documents/Tome/Meetings/Standup - Transcript.md", // absolute, when complete
  "error": "…"                                       // when state == "failed"
}
// 404 { "error": "unknown sessionGuid" } — never seen, or evicted (retain the last 20 completed/failed sessions)
```

State mapping from existing machinery: `.recording` while capture is live; `transcribing` from enqueue into `PostProcessingQueue` through `finalizing` (collapse `queued|diarizing|reTranscribing|finalizing` — WhisperCal only needs the coarse state); `complete` on `.complete(URL)`; `failed` on `.failed` / `.discarded` / `.cancelled` (put the phase name or error message in `error`).

### `GET /status` (global, additive)

`WhisperCalRecordingInfo` gains `sessionGuid`:

```jsonc
{ "state": "recording", "recording": { "subject": "…", "suggestedFilename": "…", "sessionGuid": "3f1c…" } }
```

Global lifecycle semantics (auto-reset to `idle` after 5 s, `APIServer.swift:183-208`) are unchanged — new WhisperCal stops depending on the global state entirely.

### Artifacts

- Transcript frontmatter gains `session_guid: "3f1c…"` — written by the **live** logger at session start (so a crash-orphaned transcript already carries it) and preserved through finalize/rename.
- Voiceprint sidecar gains top-level `"sessionGuid"`. **Schema stays 1** — additive optional field; WhisperCal's decoder ignores unknown fields, and bumping the schema would break older consumers for no benefit.

### Compatibility matrix

| | old Tome | new Tome |
|---|---|---|
| **old WhisperCal** | today | no guid supplied → Tome mints; extra fields ignored downstream. Zero behavior change visible to old WhisperCal. |
| **new WhisperCal** | bare `{"ok":true}` → WhisperCal detects missing echo, runs legacy flow | full GUID flow |

---

## Tome changes

All paths relative to `Tome/Sources/Tome/`.

### 1. API models — `API/APIModels.swift`

- `WhisperCalStartRequest` gains `let sessionGuid: String?` (top-level, sibling of `suggestedFilename`).
- New response structs:

```swift
struct WhisperCalStartResponse: Codable, Sendable {
    let ok: Bool
    let sessionGuid: String
    let sessionId: String
}

struct SessionGuidStatusResponse: Codable, Sendable {
    let sessionGuid: String
    let sessionId: String
    let state: String            // recording | transcribing | complete | failed
    let startedAt: String?
    let transcriptFilename: String?
    let transcriptPath: String?
    let error: String?
}
```

- `WhisperCalRecordingInfo` gains `let sessionGuid: String?`.
- Add `sessionGuid` to `SessionStartResponse` (the full `POST /sessions/start` API) for parity.
- Update the embedded OpenAPI 3.1 spec (`APIServer.swift:1002-1266`): new request/response fields, the new path, and fix the existing doc for `calendarEventId` if it claims persistence.

### 2. API server state — `API/APIServer.swift`

The lock-guarded `State` struct (`APIServer.swift:32-49`) gains a guid-keyed session table replacing/augmenting the existing `[String: SessionLifecycleState]` dict (`:39`):

```swift
struct TrackedSession {
    let sessionGuid: String
    let sessionId: String
    var state: SessionLifecycleState      // extend enum or track failed separately
    var startedAt: Date
    var transcriptURL: URL?               // final URL, set on completion
    var errorMessage: String?
    var finishedAt: Date?
}
// State gains:
var sessionsByGuid: [String: TrackedSession] = [:]   // insertion-ordered eviction below
var guidOrder: [String] = []                          // for capped retention
```

Retention: keep every live session plus the most recent **20** finished (`complete`/`failed`) sessions; evict oldest-finished beyond that. No timers — evict at insertion time.

### 3. Handlers — `API/APIServer.swift`

**`handleWhisperCalStart` (:427-472):**

```swift
let sessionGuid = req?.sessionGuid.flatMap { $0.isEmpty ? nil : $0 }
    ?? UUID().uuidString.lowercased()
let sessionId = SessionStore.generateSessionId()
// register TrackedSession(state: .recording, startedAt: now) in sessionsByGuid
// thread sessionGuid through onStart (see §4)
// respond with WhisperCalStartResponse instead of the bare {"ok":true} literal
```

Same treatment in `handleStartSession` (:508) — accept an optional guid, mint otherwise, include it in `SessionStartResponse`.

**`handleWhisperCalStatus` (:485-505):** include `sessionGuid` in the `recording` object when recording.

**New route** in the router (:370-411): `GET /sessions/by-guid/{guid}/status` → `handleSessionGuidStatus`. Look up `sessionsByGuid[guid]`; 404 JSON on miss; otherwise map `TrackedSession` → `SessionGuidStatusResponse` (derive `transcriptFilename` from `transcriptURL.lastPathComponent`). Route ordering: register before the existing `/sessions/{id}/status` pattern match so `by-guid` isn't captured as an `{id}`.

**Completion/failure plumbing:** `sessionDidComplete` (:183-208) currently flips the global state. Extend the notification path from `PostProcessingQueue`/`PostProcessingJob` so the server learns, per guid: transition to `transcribing` at enqueue, then `complete` **with the final transcript URL** (the `.complete(URL)` phase payload already carries it) or `failed` with a message. Concretely: give `APIServer` methods like `sessionDidEnqueue(guid:)`, `sessionDidComplete(guid:finalURL:)`, `sessionDidFail(guid:message:)` and call them from wherever the job phase transitions surface on MainActor (mirror however `sessionDidComplete` is wired today). All mutations go through the existing `withState`/lock pattern — the server is not MainActor-bound.

**Off-API starts:** menu-bar / voice-memo sessions never hit the HTTP handlers, so registration must also happen from the app side: when `ContentView.startSession` runs (see §4), inform the server (`server.registerSession(guid:sessionId:)`) so `/sessions/by-guid/` works for manual sessions too. If the API server isn't running, skip silently.

### 4. Threading the guid through the session pipeline

The guid must ride every hop the `sessionId` already rides:

- **`onStart` closure** (`APIServer.swift:70`): signature gains the guid — `(SessionType, String /*sessionId*/, String /*sessionGuid*/, MeetingContext?, String? /*suggestedFilename*/)`.
- **`ContentView.startSession`** (`ContentView.swift:617-649`): accept the guid from the API path; for manual/voice-memo starts mint `UUID().uuidString.lowercased()` here. Stop passing `calendarEventId: nil` blindly — while in this code, persist `meetingContext.calendarEventId` into the snapshot too (cheap, and WhisperCal already sends it; add `calendar_event_id` to frontmatter only if trivial, otherwise leave a TODO — it is not required by this design).
- **`Models/Models.swift`:**
  - `SessionRecordingContext` (:59-65) gains `let sessionGuid: String`.
  - `TranscriptSessionSnapshot` (:91-126) gains `let sessionGuid: String` (it currently has *no* id at all).
  - `SessionHandle` (:134-153) gains `let sessionGuid: String`.
- **`Recovery/SessionSidecar.swift`** (:12-27): add `sessionGuid` and bump `currentSchema` (internal artifact, deleted on success; `OrphanScanner` decode must tolerate old sidecars without the field — make it optional).
- **`Transcription/PostProcessingJob.swift`:** carry the guid (via `SessionHandle`); on phase transitions call the APIServer notification hooks (§3). On orphan-recovery jobs (launched by `OrphanScanner` from an old sidecar without a guid), mint a fresh guid so the finalized artifacts are still stamped.

### 5. Artifacts

- **`Storage/TranscriptLogger.swift` `startSession` (:103-134):** add `session_guid: "<guid>"` to the initial frontmatter template (place it after `source_file:`). Written live at session start by design — this is what makes crash-orphaned transcripts recoverable by guid.
- **`Storage/TranscriptFinalizer.swift` `rewriteFrontmatter` (:354-381):** preserve `session_guid` through the rewrite (verify the rewrite is key-preserving for unknown keys; if it rebuilds frontmatter from the snapshot, emit the guid from `TranscriptSessionSnapshot.sessionGuid`). The rename/relocate paths (`relocateRenamedNote` :263-300) move the whole file, so no extra work — but confirm no path re-emits frontmatter without the key.
- **`Storage/VoiceprintSidecar.swift`** (:18-43): add `let sessionGuid: String?` to the struct; populate from the snapshot in `PostProcessingJob` (:256-276). `currentSchema` stays **1**.
- Retained `.m4a` export: no metadata change (correlation to the transcript remains the shared basename; the transcript's frontmatter carries the guid).

### 6. Out of scope

- Replacing the internal `sessionId` or any Application Support file naming.
- JSONL record format (`SessionRecord`) — untouched.
- Any change to diarization, the queue's serial semantics, or the `.transcribing`-is-not-a-blocker gate (`APIServer.swift:437-454`) — the guid rides the existing concurrency model.

---

## Testing checklist

1. **API round-trip:** `curl -X POST localhost:27080/start -d '{"sessionGuid":"11111111-1111-4111-8111-111111111111","suggestedFilename":"T1"}'` → response echoes guid + sessionId. `GET /sessions/by-guid/1111…/status` → `recording`. Stop → `transcribing` → `complete` with `transcriptFilename`/`transcriptPath` pointing at the real final file.
2. **Mint-when-absent:** `POST /start` without `sessionGuid` → response contains a fresh v4 guid; transcript frontmatter has it.
3. **Manual session:** menu-bar recording (no API) → transcript + sidecar carry a minted guid; `/sessions/by-guid/` resolves it while Tome runs.
4. **Concurrent:** stop session A, start session B while A post-processes. `by-guid/A` reports `transcribing`→`complete`; `by-guid/B` reports `recording` — simultaneously and independently. Global `/status` shows `recording` with B's guid.
5. **Filename collision:** two sessions with the same `suggestedFilename` → each `by-guid` status returns its own `-1`-suffixed final filename.
6. **Failure:** force a post-processing failure → `by-guid` returns `failed` + `error`.
7. **Retention:** run >20 sessions → oldest evicted (404), live + recent still resolve.
8. **Old client:** replay today's exact WhisperCal requests (no guid, reads only `ok`/global status) → byte-compatible behavior apart from additive JSON fields.
9. **Crash recovery:** kill Tome mid-recording → relaunch → `OrphanScanner` refinalizes; transcript keeps the guid stamped at session start; old-schema sidecars (no guid) still decode.
10. Voice memo path unaffected apart from the new frontmatter key.
