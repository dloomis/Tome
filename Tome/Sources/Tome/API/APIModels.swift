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
    let meetingContext: MeetingContext?
}

/// Request body for POST /api/v1/start (WhisperCal integration)
struct WhisperCalStartRequest: Codable, Sendable {
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

struct SessionStartResponse: Codable, Sendable {
    let sessionId: String
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
