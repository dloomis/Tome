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
