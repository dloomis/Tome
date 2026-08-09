import Foundation
import Observation
import os

/// How the offline transcription pass ended. Deliberately separate from
/// `ImportError`: the pass reports *what happened to the audio*, and
/// `ImportJob.disposition` decides what that means for the artifacts on disk.
enum ImportPassOutcome: Equatable, Sendable {
    /// The whole file was read and the transcriber drained normally.
    case completed
    /// A decode/read error interrupted the pass. Carries the reader's message.
    case readFailed(String)
    /// The pass couldn't run for a reason that has nothing to do with the file
    /// (VAD/ASR models unavailable). Kept distinct from `.readFailed` so a
    /// broken engine is never reported as a broken recording.
    case engineFailed(String)
    /// The user cancelled; the pass stopped feeding audio and drained.
    case cancelled
}

/// What the import stage does with the artifacts it created (§8).
///
/// The single rule, and the easiest thing in the feature to invert:
/// **zero utterances → unwind; any utterances at all → keep and hand off.**
/// Nothing else — not *why* the pass ended — moves the decision. A partial
/// transcript plus a complete WAV copy is recoverable by the ordinary
/// post-processing pipeline (and, if that fails, by the orphan scan /
/// `.failed.json` machinery); deleting it is unrecoverable. An empty note plus
/// a WAV copy is pure litter in the vault, and for an imported file it is
/// almost certainly a mistake (§6.1), so it is removed.
enum ImportDisposition: Equatable, Sendable {
    /// Keep every artifact and enqueue a standard `PostProcessingJob`.
    case handOff
    /// Delete every artifact this job created and report `error` — `nil` for a
    /// plain user cancel, which is not a failure to announce.
    case unwind(ImportError?)
}

/// Cancel flag shared between the main-actor `ImportJob` and the offline pass,
/// which runs off the main actor and must be able to check it between chunks
/// without hopping actors.
final class ImportCancelToken: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// One file's import-stage state machine (§6.1), mirroring `PostProcessingJob`'s
/// shape: an `@Observable` main-actor object the UI can bind to directly, driven
/// entirely by `ImportCoordinator`.
///
/// The job also owns the **rollback list** — every artifact it created, in
/// creation order. Nothing else tracks them: the note lives in the vault, the
/// WAV copy / sidecar / JSONL live in the sessions directory, and only this
/// object knows they belong to one aborted import.
@Observable
@MainActor
final class ImportJob: Identifiable {

    enum Phase: Equatable, Sendable {
        case queued
        case validating
        case preparing
        case transcribing
        /// Artifacts kept; a `PostProcessingJob` was enqueued. The import stage
        /// is done — everything after this is the ordinary pipeline's business.
        case handedOff
        /// Rolled back and reported, with a cause attributable to the file.
        case failed(ImportError)
        /// Rolled back after something that is *not* the user's file broke:
        /// the vault was unwritable, the sessions directory unusable, the
        /// VAD/ASR models unavailable. Carries the underlying message because
        /// no `ImportError` case honestly describes it — reusing `.notReadable`
        /// here would blame a perfectly good recording.
        case failedInternal(String)
        /// Rolled back at the user's request (nothing had landed in the note).
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .queued, .validating, .preparing, .transcribing: false
            case .handedOff, .failed, .failedInternal, .cancelled: true
            }
        }

        /// User-facing text for a terminal phase, or nil when there is nothing
        /// to announce (in progress, handed off, or cancelled by the user).
        var errorText: String? {
            switch self {
            case .failed(let error): error.errorDescription
            case .failedInternal(let message): message
            default: nil
            }
        }
    }

    nonisolated let id: String
    nonisolated let sourceURL: URL

    /// `REC0034.wav` — what error messages and the status row show.
    nonisolated var displayName: String { sourceURL.lastPathComponent }
    /// `REC0034` — becomes the note's `sessionContext`, so the finalized
    /// filename carries the source recording's name (§11.2).
    nonisolated var sourceStem: String { sourceURL.deletingPathExtension().lastPathComponent }

    private(set) var phase: Phase = .queued

    /// Recording window derived from file metadata + audio length (§4). Set once
    /// validation succeeds; nil before that.
    private(set) var timestamps: ImportSupport.DerivedTimestamps?

    private(set) var framesConsumed: Int64 = 0
    private(set) var totalFrames: Int64 = 0

    /// Exact — unlike live capture, the file length is known up front.
    var progressFraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, max(0, Double(framesConsumed) / Double(totalFrames)))
    }

    /// Utterances the offline pass committed. The rollback decision turns on
    /// this being zero (§8), so it is only ever incremented by the write path.
    private(set) var utteranceCount = 0

    /// Everything this job created, in creation order. Unwound newest-first.
    private(set) var artifacts: [URL] = []

    private(set) var sessionId: String?
    private(set) var sessionGuid: String?
    private(set) var transcriptURL: URL?
    private(set) var micWavURL: URL?

    /// Shared with the offline pass (which runs off the main actor).
    nonisolated let cancelToken = ImportCancelToken()
    var isCancelRequested: Bool { cancelToken.isCancelled }

    init(sourceURL: URL, id: String = UUID().uuidString) {
        self.id = id
        self.sourceURL = sourceURL
    }

    // MARK: - Transitions

    func enter(_ phase: Phase) {
        self.phase = phase
    }

    func setTimestamps(_ stamps: ImportSupport.DerivedTimestamps) {
        timestamps = stamps
    }

    func setSession(id: String, guid: String) {
        sessionId = id
        sessionGuid = guid
    }

    /// Record an artifact for rollback. Also the only way `transcriptURL` /
    /// `micWavURL` get set, so an artifact can never be created without being
    /// tracked.
    func trackArtifact(_ url: URL, as kind: ArtifactKind = .other) {
        artifacts.append(url)
        switch kind {
        case .transcript: transcriptURL = url
        case .micWav: micWavURL = url
        case .other: break
        }
    }

    enum ArtifactKind: Sendable {
        case transcript
        case micWav
        case other
    }

    func updateProgress(framesConsumed: Int64, totalFrames: Int64) {
        self.framesConsumed = framesConsumed
        self.totalFrames = totalFrames
    }

    func setTotalFrames(_ frames: Int64) {
        totalFrames = frames
    }

    func setUtteranceCount(_ count: Int) {
        utteranceCount = count
    }

    /// Request cancellation. Cooperative: the pass stops feeding audio at the
    /// next chunk boundary and drains, then the coordinator applies the same
    /// zero-vs-partial rule every other failure goes through.
    func cancel() {
        cancelToken.cancel()
    }

    // MARK: - Rollback

    /// Delete every tracked artifact, newest first, and return what was removed.
    /// Best-effort by design: a file already gone (or a vault that vanished
    /// mid-import) must not turn a rollback into a second failure.
    ///
    /// Callers must have closed the `TranscriptLogger` / `SessionStore` writing
    /// these files before calling — deleting a path out from under an open
    /// handle leaves the writer appending to an unlinked inode.
    @discardableResult
    func rollbackArtifacts() -> [URL] {
        var removed: [URL] = []
        for url in artifacts.reversed() {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(url)
                } catch {
                    diagLogError("[IMPORT] rollback could not remove \(url.lastPathComponent): \(error)")
                }
            }
        }
        artifacts.removeAll()
        transcriptURL = nil
        micWavURL = nil
        return removed
    }

    // MARK: - The rule (§8)

    /// Decide what happens to the artifacts, given how the pass ended and how
    /// much transcript landed. Pure and total — the whole of §8 lives here so it
    /// can be table-tested without a vault, a file, or a transcriber.
    ///
    /// - Parameter utteranceCount: utterances that actually reached the note.
    ///   Callers derive it from the logger's own record (a snapshot with a
    ///   non-empty `speakersDetected`) as well as the write-path counter, and
    ///   pass the *larger* signal: over-counting keeps a recoverable transcript,
    ///   under-counting destroys one.
    static func disposition(
        outcome: ImportPassOutcome,
        utteranceCount: Int,
        filename: String
    ) -> ImportDisposition {
        // Anything landed → keep it, whatever went wrong afterwards. Mirrors
        // `ContentView.rollbackFailedStart`, which deletes the note only when
        // `snapshot.speakersDetected.isEmpty`.
        guard utteranceCount == 0 else { return .handOff }

        switch outcome {
        case .completed:
            // A silent / non-speech file. Native sessions keep an empty note
            // (the user chose to record); an imported one is a mistake (§6.1).
            return .unwind(.noSpeech(filename: filename))
        case .readFailed:
            // Not `.notReadable`: the file already passed the decode gate, so a
            // mid-pass read error is an interruption on Tome's copy, not proof
            // the user's recording is broken.
            return .unwind(.interrupted(filename: filename))
        case .engineFailed, .cancelled:
            // No typed error: a cancel is not a failure to announce, and an
            // engine failure isn't the file's fault. The caller supplies the
            // message for the latter (`Phase.failedInternal`).
            return .unwind(nil)
        }
    }
}
