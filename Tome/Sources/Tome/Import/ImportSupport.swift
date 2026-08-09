@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Typed, user-facing failures of the import stage. A closed set: every case
/// carries the source file's display name so the message can be shown verbatim
/// in the import status row and in the fallback notification.
enum ImportError: LocalizedError, Equatable, Sendable {
    /// Type gate (§5.1) — not a WAV by declared content type or extension.
    case notSupportedType(filename: String)
    /// Decode gate (§5.2) — `AVAudioFile` refused it, or the format is degenerate.
    case notReadable(filename: String)
    /// Below Parakeet's floor (§5.3).
    case tooShort(filename: String)
    /// Beyond any plausible memo (§5.3).
    case tooLong(filename: String)
    /// The file is a Tome artifact (§5.4).
    case selfImport(filename: String)
    /// The offline pass produced no utterances (§6.1) — rolled back, not saved.
    case noSpeech(filename: String)
    /// A read error interrupted the pass mid-file. Distinct from `.notReadable`:
    /// this path is only reachable after the file passed the decode gate, so the
    /// failure is an I/O interruption on Tome's own copy — blaming the recording
    /// would invite the user to delete a perfectly good original.
    case interrupted(filename: String)

    var errorDescription: String? {
        switch self {
        case .notSupportedType(let name):
            return "Couldn't import \(name): not a WAV file"
        case .notReadable(let name):
            return "Couldn't import \(name): not a readable WAV file"
        case .tooShort(let name):
            return "Couldn't import \(name): too short to transcribe"
        case .tooLong(let name):
            return "Couldn't import \(name): too long to import"
        case .selfImport(let name):
            return "Couldn't import \(name): that file was created by Tome"
        case .noSpeech(let name):
            return "No speech detected in \(name)"
        case .interrupted(let name):
            return "Import of \(name) was interrupted — try importing it again"
        }
    }
}

/// Pure helpers shared by the import pipeline: timestamp derivation (§4) and the
/// validation gates (§5). Deliberately free of app state — every input is passed
/// in, so each rule is unit-testable without a vault, a session directory, or a
/// running app.
enum ImportSupport {

    // MARK: - Timestamp derivation (§4)

    /// Which piece of file metadata the derived session start was anchored on.
    /// Reported so the caller can `diagLog` the choice.
    enum TimestampAnchor: String, Sendable {
        /// `creationDate` — the recorder stamped the file at recording start.
        case creationDate
        /// `modificationDate − duration` — the convention `Recovery.run` uses.
        case modificationDate
        /// `now − duration` — no usable metadata survived the copy.
        case importTime
    }

    struct DerivedTimestamps: Equatable, Sendable {
        let start: Date
        let end: Date
        let anchor: TimestampAnchor
    }

    /// A date is usable only if it is a real wall-clock stamp: not epoch zero (or
    /// before — the signature of metadata that was never set) and not in the
    /// future relative to `now` (clock-skewed cameras, some cloud syncs).
    static func isPlausibleFileDate(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return date.timeIntervalSince1970 > 0 && date <= now
    }

    /// Derive the recording window from file metadata plus the decoded audio
    /// length. `end` is always `start + duration`, so the finalized note's
    /// `duration:` is the exact audio length regardless of which anchor won.
    static func deriveTimestamps(
        creationDate: Date?,
        modificationDate: Date?,
        duration: TimeInterval,
        now: Date
    ) -> DerivedTimestamps {
        let start: Date
        let anchor: TimestampAnchor
        if isPlausibleFileDate(creationDate, now: now), let creationDate {
            start = creationDate
            anchor = .creationDate
        } else if isPlausibleFileDate(modificationDate, now: now), let modificationDate {
            start = modificationDate.addingTimeInterval(-duration)
            anchor = .modificationDate
        } else {
            start = now.addingTimeInterval(-duration)
            anchor = .importTime
        }
        return DerivedTimestamps(start: start, end: start.addingTimeInterval(duration), anchor: anchor)
    }

    /// `creationDate` / `modificationDate` for a file, both optional — a missing
    /// attribute and an unreadable file are the same thing to the caller, which
    /// falls back either way.
    static func fileDates(at url: URL) -> (creation: Date?, modification: Date?) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attrs[.creationDate] as? Date, attrs[.modificationDate] as? Date)
    }

    // MARK: - Type gate (§5.1)

    /// Content types the import stage accepts. v1 is WAV-only; widening this is
    /// the one-line change that admits `.m4a` / `.mp3` (§2).
    static let acceptedContentTypes: [UTType] = [.wav]

    /// True when the URL declares (or is named) one of `acceptedContentTypes`.
    /// The declared type wins; extension matching is the fallback for files whose
    /// type the system can't resolve (network volumes, freshly written temp files).
    static func conformsToAcceptedType(_ url: URL) -> Bool {
        if let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return acceptedContentTypes.contains { declared.conforms(to: $0) }
        }
        let ext = url.pathExtension
        guard !ext.isEmpty, let byExtension = UTType(filenameExtension: ext) else { return false }
        return acceptedContentTypes.contains { byExtension.conforms(to: $0) }
    }

    static func validateType(_ url: URL) throws {
        guard conformsToAcceptedType(url) else {
            throw ImportError.notSupportedType(filename: url.lastPathComponent)
        }
    }

    // MARK: - Decode gate (§5.2)

    /// What the decode gate learned about a candidate file. `duration` is the
    /// same math `Recovery.inspectWAV` uses.
    struct AudioFileInfo: Equatable, Sendable {
        let sampleRate: Double
        let channelCount: UInt32
        let frameLength: Int64
        let duration: TimeInterval
    }

    /// Open the file and prove it is decodable linear PCM with real content.
    /// A renamed JPEG with a `.wav` extension dies here.
    static func inspectAudioFile(at url: URL) throws -> AudioFileInfo {
        let filename = url.lastPathComponent
        guard let file = try? AVAudioFile(forReading: url) else {
            throw ImportError.notReadable(filename: filename)
        }
        let format = file.processingFormat
        guard format.commonFormat != .otherFormat,
              format.sampleRate > 0,
              format.channelCount >= 1,
              file.length > 0
        else {
            throw ImportError.notReadable(filename: filename)
        }
        return AudioFileInfo(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameLength: file.length,
            duration: Double(file.length) / format.sampleRate
        )
    }

    // MARK: - Duration bounds (§5.3)

    /// Parakeet's floor, mirroring `SegmentReTranscriber.minSamples`.
    static let minimumDuration: TimeInterval = 1.5
    /// Beyond any plausible memo; also protects the retention mixer and diarizer.
    static let maximumDuration: TimeInterval = 8 * 60 * 60

    static func validateDuration(_ duration: TimeInterval, filename: String) throws {
        if duration < minimumDuration { throw ImportError.tooShort(filename: filename) }
        if duration > maximumDuration { throw ImportError.tooLong(filename: filename) }
    }

    // MARK: - Self-import guard (§5.4)

    /// True when `url` lives inside `directory` (at any depth). Symlink-resolved
    /// and component-wise, so `/tmp/sessions-old/x.wav` is not treated as being
    /// inside `/tmp/sessions`.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dir = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard dir.count < file.count else { return false }
        return Array(file.prefix(dir.count)) == dir
    }

    /// Refuse a file that already lives in one of Tome's own directories — the
    /// sessions directory or a configured output folder. Callers pass whichever
    /// of those are configured; `nil`/empty entries are simply absent from the list.
    static func validateNotSelfImport(_ url: URL, protectedDirectories: [URL]) throws {
        for dir in protectedDirectories where isContained(url, in: dir) {
            throw ImportError.selfImport(filename: url.lastPathComponent)
        }
    }
}
