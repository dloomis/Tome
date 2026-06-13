import Foundation

/// Per-speaker acoustic voiceprints written next to a finalized transcript as
/// `<stem>.voiceprints.json`. Each speaker's `embedding` is an L2-normalized centroid
/// produced by diarization (SpeakerKit `DiarizationResult.speakerCentroidEmbeddings`).
///
/// This is a deliberately neutral artifact. Tome emits anonymous centroids keyed by the
/// same `Speaker N` labels as the transcript body; a downstream tool (e.g. WhisperCal)
/// binds a centroid to a real person off the speaker-tag confirmation the user already
/// makes. Tome itself never learns who anyone is. The vectors are biometric, so emission
/// is opt-in (`AppSettings.exportVoiceprints`).
///
/// Schema is versioned and carries `model` so a consumer can refuse to compare or merge
/// embeddings produced by different diarization models (the vectors live in different
/// spaces). See `docs/voiceprints.md` for the full binding contract.
struct VoiceprintSidecar: Codable, Sendable {
    /// Bump when the on-disk shape changes.
    static let currentSchema = 1

    /// Embedding-space identity. Consumers MUST refuse to compare/merge across differing
    /// values. Bump whenever the diarization model changes (pyannote v4 → v5, etc.).
    static let modelIdentity = "speakerkit-1.0"

    struct Speaker: Codable, Sendable {
        let embedding: [Float]
        /// Total diarized speech attributed to this label — a quality floor a consumer
        /// can use to skip a flimsy drive-by centroid.
        let activeSeconds: Double
        let segmentCount: Int
    }

    let schema: Int
    let model: String
    let dimension: Int
    /// Which stream was diarized: `system` (call capture), `mic`, or `mixed` (backfill).
    let source: String
    /// True when the diarized stream includes the recording user (mic-only sessions).
    let includesYou: Bool
    /// Keyed by transcript labels ("Speaker 2", …) so a consumer can join a centroid to
    /// the label it confirmed during speaker tagging.
    let speakers: [String: Speaker]

    /// Sibling path convention: `<transcript-stem>.voiceprints.json`.
    static func sidecarURL(forTranscript transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("voiceprints.json")
    }

    /// Build a sidecar from a diarization output. Centroids are re-keyed from raw
    /// "SPEAKER_n" ids to the friendly labels the transcript body uses, via the shared
    /// `speakerLabels` map, so the keys line up with what the speaker-tag step sees.
    /// Returns nil when there is nothing worth writing.
    static func build(from diar: DiarizationOutput, source: String, includesYou: Bool) -> VoiceprintSidecar? {
        guard !diar.centroids.isEmpty else { return nil }

        let labelMap = speakerLabels(from: diar.segments.map(\.speakerId))

        var activeSeconds: [String: Double] = [:]
        var segmentCounts: [String: Int] = [:]
        for seg in diar.segments {
            guard let label = labelMap[seg.speakerId] else { continue }
            activeSeconds[label, default: 0] += Double(seg.endTime - seg.startTime)
            segmentCounts[label, default: 0] += 1
        }

        var speakers: [String: Speaker] = [:]
        var dimension = 0
        for (rawId, vector) in diar.centroids {
            guard let label = labelMap[rawId], !vector.isEmpty else { continue }
            dimension = vector.count
            speakers[label] = Speaker(
                embedding: vector,
                activeSeconds: activeSeconds[label] ?? 0,
                segmentCount: segmentCounts[label] ?? 0
            )
        }
        guard !speakers.isEmpty else { return nil }

        return VoiceprintSidecar(
            schema: currentSchema,
            model: modelIdentity,
            dimension: dimension,
            source: source,
            includesYou: includesYou,
            speakers: speakers
        )
    }

    static func write(_ sidecar: VoiceprintSidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)
        try data.write(to: url, options: .atomic)
    }
}
