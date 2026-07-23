import Foundation

/// Machine-readable record of a post-processing failure, written as
/// `<sessionId>.failed.json` next to the session's JSONL and capture WAVs.
/// A failed job already notifies the user and preserves its WAVs for the
/// orphan scan — the marker is for tooling: it lets recovery scripts find
/// failed sessions (and why they failed) without parsing the unified log.
///
/// Lifecycle: written by `PostProcessingQueue` when a job throws (never on
/// cancellation — that's an unfinished session, not a failure); deleted by the
/// job's verified-success cleanup and by `OrphanScanner.discard`.
struct JobFailureMarker: Codable, Sendable {
    static let currentSchema = 1

    let schema: Int
    let sessionId: String
    /// Correlation GUID; nil when the session predates guid stamping.
    let sessionGuid: String?
    let sessionType: SessionType
    let failedAt: Date
    /// The user-facing failure message (same text as the notification).
    let error: String
    /// Where the transcript was expected — may no longer exist.
    let transcriptPath: String
    let wavBufferPath: String?
    let micWavPath: String?

    static func markerURL(forSessionId id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id).failed.json")
    }

    /// Best-effort write for a failed job. No capture directory (a handle with no
    /// WAV paths — test-shaped sessions only) means nowhere sensible to put it.
    static func emit(for handle: SessionHandle, message: String) {
        guard let dir = handle.captureDirectory else {
            diagLog("[MARKER] no capture directory for \(handle.id) — failure marker not written")
            return
        }
        let marker = JobFailureMarker(
            schema: currentSchema,
            sessionId: handle.id,
            sessionGuid: handle.sessionGuid.isEmpty ? nil : handle.sessionGuid,
            sessionType: handle.sessionType,
            failedAt: Date(),
            error: message,
            transcriptPath: handle.transcript.filePath.path,
            wavBufferPath: handle.wavBufferPath?.path,
            micWavPath: handle.micWavPath?.path
        )
        let url = markerURL(forSessionId: handle.id, in: dir)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(marker).write(to: url, options: .atomic)
            diagLog("[MARKER] wrote \(url.lastPathComponent)")
        } catch {
            diagLog("[MARKER] write failed for \(url.lastPathComponent): \(error)")
        }
    }

    static func read(from url: URL) throws -> JobFailureMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JobFailureMarker.self, from: Data(contentsOf: url))
    }

    static func deleteIfExists(forSessionId id: String, in directory: URL) {
        try? FileManager.default.removeItem(at: markerURL(forSessionId: id, in: directory))
    }
}
