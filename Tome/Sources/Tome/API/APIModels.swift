import Foundation

// MARK: - Request Types

/// Meeting context passed by WhisperCal when starting a recording.
struct MeetingContext: Codable, Sendable {
    let subject: String?
    let attendees: [String]?
    let calendarEventId: String?
    let startTime: String?
}

/// Request body for POST /api/v1/sessions/start
struct StartSessionRequest: Codable, Sendable {
    let type: String
    /// Caller-supplied correlation key (see `WhisperCalStartRequest.sessionGuid`).
    let sessionGuid: String?
    let meetingContext: MeetingContext?
}

/// Request body for POST /api/v1/start (WhisperCal integration)
struct WhisperCalStartRequest: Codable, Sendable {
    /// Caller-supplied correlation key for this session, echoed in the response
    /// and stamped into every output artifact. Any non-empty string ≤ 64 chars
    /// is accepted (canonically a lowercase UUIDv4); Tome mints one when absent.
    let sessionGuid: String?
    let suggestedFilename: String?
    let meetingContext: MeetingContext?
}

/// Request body for POST /api/v1/sessions/stop
struct StopSessionRequest: Codable, Sendable {
    let sessionId: String
}

// MARK: - Response Types

struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
    let isRecording: Bool
    let modelsReady: Bool
}

/// The active recording's identity, echoed by GET /status while a session is
/// recording (or transcribing) so callers can show *which* meeting is captured.
struct WhisperCalRecordingInfo: Codable, Sendable {
    let subject: String?
    let suggestedFilename: String?
    /// The session GUID (caller-supplied or Tome-minted) of the in-flight session.
    let sessionGuid: String?
}

/// Response body for POST /api/v1/start — echoes the correlation identifiers so
/// the caller can track this exact session through `/sessions/by-guid/`. Replaces
/// the historical bare `{"ok":true}` literal; old clients that only read `ok`
/// are unaffected by the additive fields.
struct WhisperCalStartResponse: Codable, Sendable {
    let ok: Bool
    let sessionGuid: String
    let sessionId: String
}

/// Response body for GET /api/v1/sessions/by-guid/{guid}/status.
struct SessionGuidStatusResponse: Codable, Sendable {
    let sessionGuid: String
    let sessionId: String
    let state: String            // recording | transcribing | complete | failed
    /// ISO 8601 start moment — present while recording.
    let startedAt: String?
    /// Final transcript basename, after collision suffixes and renames — when complete.
    let transcriptFilename: String?
    /// Absolute path of the finalized transcript — when complete.
    let transcriptPath: String?
    /// Failure phase or message — when state == "failed".
    let error: String?
}

/// Response body for GET /api/v1/status (WhisperCal integration). `recording` is
/// present only while a session is active; nil optionals are dropped by the
/// encoder, so an idle response stays `{"state":"idle"}`.
struct WhisperCalStatusResponse: Codable, Sendable {
    let state: String
    let recording: WhisperCalRecordingInfo?
}

struct SessionStartResponse: Codable, Sendable {
    let sessionId: String
    /// Correlation key for `/sessions/by-guid/` — echoed if supplied, minted otherwise.
    let sessionGuid: String
    let status: String
}

struct SessionStopResponse: Codable, Sendable {
    let sessionId: String
    let status: String
}

struct SessionStatusResponse: Codable, Sendable {
    let sessionId: String
    let status: String
    let elapsedSeconds: Int
    let speakerCount: Int
    let lineCount: Int
}

/// Matches WhisperCal's TranscriptData.lines[n]
struct TranscriptLine: Codable, Sendable {
    let speaker: String?
    let text: String
    let startMs: Int
}

/// Matches WhisperCal's SpeakerInfo
struct APISpeakerInfo: Codable, Sendable {
    let name: String
    let id: String
    let isStub: Bool
    let lineCount: Int
}

/// Matches WhisperCal's TranscriptData.metadata
struct TranscriptMetadata: Codable, Sendable {
    let title: String?
    let dateCreated: String
    let hasBeenDiarized: Bool
    let durationSec: Int?
    let sourceApp: String?
}

/// Matches WhisperCal's TranscriptData
struct TranscriptResponse: Codable, Sendable {
    let lines: [TranscriptLine]
    let metadata: TranscriptMetadata?
    let speakers: [APISpeakerInfo]
}

/// Session summary for listing
struct SessionSummary: Codable, Sendable {
    let sessionId: String
    let title: String?
    let recordingStart: String
    let dateCreated: String?
    let durationSeconds: Int
    let speakerCount: Int
    let status: String
}

struct SessionListResponse: Codable, Sendable {
    let sessions: [SessionSummary]
}
