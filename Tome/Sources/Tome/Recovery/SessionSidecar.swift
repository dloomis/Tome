import Foundation

/// Per-session metadata persisted next to the WAV so orphan recovery is
/// deterministic instead of heuristic. When a capture starts we write
/// `{sessionId}.session.json` alongside `{sessionId}.wav`; the post-processing
/// success path deletes both. A crash leaves both files on disk for the
/// launch-time `OrphanScanner` to pair back up with their transcript.
///
/// Schema versioning is intentional — fields are likely to evolve as recovery
/// gets smarter (multi-stream attribution, per-segment confidence priors, etc.),
/// and the reader needs to handle older sidecars gracefully.
struct SessionSidecar: Codable, Sendable {
    /// Bump when adding required fields. Current schema=1 carries everything
    /// `Recovery.run` needs to rebuild a `TranscriptSessionSnapshot`.
    static let currentSchema = 1

    let schema: Int
    let sessionId: String
    let transcriptPath: String
    let startedAt: Date
    let sourceApp: String
    let sessionType: SessionType
    let sampleRate: Double
    let channels: Int
    let bitsPerSample: Int
    let appVersion: String

    /// Resolved transcript URL. The sidecar stores a path string because the
    /// vault may live on a removable / iCloud volume whose `URL` representation
    /// changes; the path stays stable and is re-resolved at read time.
    var transcriptURL: URL { URL(fileURLWithPath: transcriptPath) }

    /// Convention: sidecar at the same stem as the WAV with `.session.json`
    /// extension. Picked over `.json` to leave room for future per-session
    /// artifacts (e.g. `.diarization.json`) without collisions.
    static func sidecarURL(forWAV wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("session.json")
    }

    /// Inverse of `sidecarURL(forWAV:)`. Strips `.session.json` → `.wav`.
    static func wavURL(forSidecar sidecarURL: URL) -> URL {
        sidecarURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("wav")
    }

    /// Best-effort sidecar write for `wavURL` from a recording context — the
    /// single emission path shared by `SystemAudioCapture` (call captures) and
    /// `TranscriptionEngine` (mic-only sessions, which previously never got a
    /// sidecar and were invisible to crash recovery). Failure is logged, never
    /// thrown: a missing sidecar degrades to manual recovery, and sidecar
    /// trouble must not block the capture itself.
    static func emit(
        forWAV wavURL: URL,
        context: SessionRecordingContext,
        sampleRate: Double,
        channels: Int = 1,
        bitsPerSample: Int = 32
    ) {
        let sidecar = SessionSidecar(
            schema: currentSchema,
            sessionId: context.sessionId,
            transcriptPath: context.transcriptURL.path,
            startedAt: context.startedAt,
            sourceApp: context.sourceApp,
            sessionType: context.sessionType,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
        let url = sidecarURL(forWAV: wavURL)
        do {
            try write(sidecar, to: url)
            diagLog("[SIDECAR] wrote \(url.lastPathComponent)")
        } catch {
            diagLog("[SIDECAR] write failed: \(error) — orphan recovery for this session won't auto-pair")
        }
    }

    static func write(_ sidecar: SessionSidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        // Atomic write — the WAV write is unsynchronized, but the sidecar is
        // small and infrequent, so atomic is fine and gives us an all-or-nothing
        // guarantee.
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> SessionSidecar {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionSidecar.self, from: data)
    }

    /// Best-effort cleanup. Used by `cleanupBufferFile` and friends so callers
    /// don't have to thread the sidecar URL separately from the WAV URL.
    static func deleteIfExists(forWAV wavURL: URL) {
        let url = sidecarURL(forWAV: wavURL)
        try? FileManager.default.removeItem(at: url)
    }

    /// Re-point the sidecar's `transcriptPath` after finalization renames the note,
    /// so a crash between the rename and cleanup leaves an orphan that auto-recovery
    /// can still pair with its transcript. Best-effort: on any failure the sidecar
    /// keeps the stale path and recovery degrades to "transcript file missing"
    /// (manual Cmd+Opt+R), exactly the pre-existing behavior.
    static func updateTranscriptPath(forWAV wavURL: URL, to newTranscriptURL: URL) {
        let url = sidecarURL(forWAV: wavURL)
        guard let old = try? read(from: url) else { return }
        let updated = SessionSidecar(
            schema: old.schema,
            sessionId: old.sessionId,
            transcriptPath: newTranscriptURL.path,
            startedAt: old.startedAt,
            sourceApp: old.sourceApp,
            sessionType: old.sessionType,
            sampleRate: old.sampleRate,
            channels: old.channels,
            bitsPerSample: old.bitsPerSample,
            appVersion: old.appVersion
        )
        do {
            try write(updated, to: url)
        } catch {
            diagLog("[SIDECAR] transcriptPath refresh failed for \(url.lastPathComponent): \(error)")
        }
    }
}
