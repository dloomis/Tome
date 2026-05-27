import Foundation

enum Speaker: String, Codable, Sendable {
    case you
    case them
}

struct Utterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date

    init(text: String, speaker: Speaker, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

// MARK: - Speaker Labels

/// Maps raw diarization speaker IDs to friendly labels ("Speaker 2", "Speaker 3", etc.).
/// Numbering starts at 2 because "You" is always the implicit first speaker.
/// Labels are assigned in encounter order.
func speakerLabels(from orderedIds: some Sequence<String>) -> [String: String] {
    var map: [String: String] = [:]
    var next = 2
    for id in orderedIds where map[id] == nil {
        map[id] = "Speaker \(next)"
        next += 1
    }
    return map
}

// MARK: - Session Recording Context

/// Per-recording identity passed from `ContentView` down through
/// `TranscriptionEngine.start` into `SystemAudioCapture.bufferStream`. Used to
/// write the WAV sidecar (see `SessionSidecar`) so an orphaned WAV always knows
/// which transcript and session it belongs to.
///
/// The engine doesn't otherwise care about this metadata — it's purely passed
/// through to the audio capture for sidecar emission.
struct SessionRecordingContext: Sendable {
    let sessionId: String
    let transcriptURL: URL
    let sourceApp: String
    let sessionType: SessionType
    let startedAt: Date
}

// MARK: - Session Record

/// Codable record for JSONL session persistence
struct SessionRecord: Codable {
    let speaker: Speaker
    let text: String
    let timestamp: Date

    init(speaker: Speaker, text: String, timestamp: Date) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Transcript Session Snapshot

/// Immutable snapshot of a session's on-disk and metadata state at `endSession()` time.
/// Passed to `TranscriptFinalizer` functions so post-processing runs without reaching
/// back into a live `TranscriptLogger` actor — which is critical when a new session
/// has already claimed the logger for its own recording.
///
/// `speakersDetected` is `var` so finalization steps can update it as diarization
/// replaces "Them" with specific speaker labels.
struct TranscriptSessionSnapshot: Sendable {
    let filePath: URL
    let sessionStartTime: Date
    var speakersDetected: Set<String>
    let sourceApp: String
    let sessionContext: String
    let suggestedFilename: String?
    /// `DateFormatter` pattern used when post-processing renames the file using
    /// session context. Captured at session start so a user changing the setting
    /// mid-recording doesn't shift the prefix on a session already in flight.
    let filenameDateFormat: String
}

// MARK: - Session Handle

/// Immutable identity + resources for one session. Handed off at stop time to a
/// `PostProcessingJob`, which finalizes in the background while a new session may
/// already be recording. `transcript` is `var` so finalization can flow updated
/// speaker information through the diarization → rebuild → finalize pipeline.
struct SessionHandle: Sendable {
    let id: String
    let sessionType: SessionType
    let sourceApp: String
    /// Path to the buffered system audio WAV. Nil when the session did not capture
    /// system audio (e.g. voice memos), which signals the job to skip diarization.
    let wavBufferPath: URL?
    /// Path to the buffered mic-track WAV (always written during capture). Combined
    /// with `wavBufferPath` by the mixer when retention is on; deleted afterward.
    let micWavPath: URL?
    /// Wall-clock of the first mic / system sample, used to align each track to the
    /// session start (`transcript.sessionStartTime`) in the combined recording.
    let micFirstSampleTime: Date?
    let systemFirstSampleTime: Date?
    var transcript: TranscriptSessionSnapshot
    /// Number of times the system-audio WAV writer threw on `write(from:)`. Non-zero
    /// values are not fatal but indicate the diarization input may be incomplete —
    /// the post-processing job logs a warning before diarizing.
    var wavWriteErrorCount: Int = 0
}

// MARK: - Recording Retention

/// Set on a `PostProcessingJob` when the user has retention enabled. Carries the
/// destination folder for the exported combined `.m4a`.
struct RecordingRetentionConfig: Sendable {
    let folder: URL
}

// MARK: - Post-Processing Error

/// Typed errors from a `PostProcessingJob.run()`. A closed set — callers must
/// handle each case.
enum PostProcessingError: Error, Sendable {
    case diarizeFailed(String)
    case reTranscribeFailed(String)
    case markdownWriteFailed(String)
    case cancelled
}
