import Foundation
import Testing
@testable import Tome

/// §8's rollback rule and the job-level state it operates on. The disposition
/// table is the centerpiece: inverting it either litters the vault with empty
/// notes or destroys a recoverable partial transcript, and neither failure is
/// visible from any other test in the suite.
@Suite @MainActor struct ImportJobTests {

    private let filename = "REC0034.wav"

    // MARK: - The rule (§8)

    /// Zero utterances is the ONLY input that unwinds, and each cause maps to
    /// its own report. Table-driven so a future case can't be added without a row.
    @Test func zeroUtterancesUnwindsWithACauseSpecificReport() {
        #expect(
            ImportJob.disposition(outcome: .completed, utteranceCount: 0, filename: filename)
                == .unwind(.noSpeech(filename: filename)),
            "a silent import must be rolled back and reported as no speech, not saved as an empty note"
        )
        #expect(
            ImportJob.disposition(outcome: .readFailed("I/O"), utteranceCount: 0, filename: filename)
                == .unwind(.interrupted(filename: filename)),
            "a mid-pass read error hit Tome's copy after the decode gate passed — it must not blame the recording"
        )
        #expect(
            ImportJob.disposition(outcome: .cancelled, utteranceCount: 0, filename: filename)
                == .unwind(nil),
            "a user cancel with nothing transcribed is not a failure to announce"
        )
        #expect(
            ImportJob.disposition(outcome: .engineFailed("no VAD"), utteranceCount: 0, filename: filename)
                == .unwind(nil),
            "an engine failure must not be reported as a broken recording"
        )
    }

    /// The inversion guard. Once *any* utterance has landed, every ending —
    /// including a mid-pass read failure and a user cancel — keeps the artifacts
    /// and hands off. The partial transcript plus the complete WAV copy is
    /// recoverable downstream; deleting it is not.
    @Test func anyUtteranceAtAllHandsOffRegardlessOfHowThePassEnded() {
        for outcome: ImportPassOutcome in [.completed, .readFailed("truncated"), .engineFailed("no VAD"), .cancelled] {
            #expect(
                ImportJob.disposition(outcome: outcome, utteranceCount: 1, filename: filename) == .handOff,
                "outcome \(outcome) with 1 utterance must hand off, not unwind"
            )
            #expect(
                ImportJob.disposition(outcome: outcome, utteranceCount: 42, filename: filename) == .handOff
            )
        }
    }

    /// The boundary itself: 0 → unwind, 1 → hand off, on the same outcome.
    @Test func theBoundaryIsExactlyOneUtterance() {
        #expect(ImportJob.disposition(outcome: .readFailed("x"), utteranceCount: 0, filename: filename)
                != .handOff)
        #expect(ImportJob.disposition(outcome: .readFailed("x"), utteranceCount: 1, filename: filename)
                == .handOff)
    }

    // MARK: - Rollback list

    @Test func rollbackRemovesEveryTrackedArtifactAndForgetsThem() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let wav = dir.appendingPathComponent("session.mic.wav")
        let sidecar = dir.appendingPathComponent("session.session.json")
        let jsonl = dir.appendingPathComponent("session.jsonl")
        let note = dir.appendingPathComponent("note.md")
        for url in [wav, sidecar, jsonl, note] {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }

        let job = ImportJob(sourceURL: dir.appendingPathComponent("REC0034.wav"))
        job.trackArtifact(wav, as: .micWav)
        job.trackArtifact(sidecar)
        job.trackArtifact(jsonl)
        job.trackArtifact(note, as: .transcript)

        let removed = job.rollbackArtifacts()

        #expect(Set(removed) == Set([wav, sidecar, jsonl, note]))
        for url in [wav, sidecar, jsonl, note] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) survived rollback")
        }
        #expect(job.artifacts.isEmpty)
        #expect(job.transcriptURL == nil)
        #expect(job.micWavURL == nil)
    }

    /// Rollback must be safe to run when part of the list never made it to disk
    /// (a prepare step that failed halfway) — it removes what exists and reports
    /// only that, instead of throwing on the first missing file.
    @Test func rollbackToleratesArtifactsThatWereNeverCreated() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let real = dir.appendingPathComponent("real.wav")
        FileManager.default.createFile(atPath: real.path, contents: Data("x".utf8))
        let missing = dir.appendingPathComponent("never-written.jsonl")

        let job = ImportJob(sourceURL: dir.appendingPathComponent("REC0034.wav"))
        job.trackArtifact(real, as: .micWav)
        job.trackArtifact(missing)

        let removed = job.rollbackArtifacts()
        #expect(removed == [real])
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }

    /// Deleting newest-first matters when a later artifact lives inside an
    /// earlier one's directory; more importantly the order is deterministic, so
    /// a rollback can be reasoned about (and replayed) from the list alone.
    @Test func rollbackUnwindsInReverseCreationOrder() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let first = dir.appendingPathComponent("1")
        let second = dir.appendingPathComponent("2")
        let third = dir.appendingPathComponent("3")
        for url in [first, second, third] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        let job = ImportJob(sourceURL: dir.appendingPathComponent("REC0034.wav"))
        job.trackArtifact(first)
        job.trackArtifact(second)
        job.trackArtifact(third)

        #expect(job.rollbackArtifacts() == [third, second, first])
    }

    // MARK: - State

    @Test func aFreshJobIsQueuedWithNothingTracked() {
        let job = ImportJob(sourceURL: URL(fileURLWithPath: "/tmp/REC0034.wav"))
        #expect(job.phase == .queued)
        #expect(job.phase.isTerminal == false)
        #expect(job.artifacts.isEmpty)
        #expect(job.utteranceCount == 0)
        #expect(job.progressFraction == 0)
        #expect(job.isCancelRequested == false)
        #expect(job.displayName == "REC0034.wav")
        #expect(job.sourceStem == "REC0034")
    }

    @Test func terminalPhasesAreTerminalAndCarryTheirText() {
        #expect(ImportJob.Phase.validating.isTerminal == false)
        #expect(ImportJob.Phase.preparing.isTerminal == false)
        #expect(ImportJob.Phase.transcribing.isTerminal == false)
        #expect(ImportJob.Phase.handedOff.isTerminal)
        #expect(ImportJob.Phase.cancelled.isTerminal)
        #expect(ImportJob.Phase.failed(.tooShort(filename: filename)).isTerminal)
        #expect(ImportJob.Phase.failedInternal("vault unwritable").isTerminal)

        #expect(ImportJob.Phase.failed(.noSpeech(filename: filename)).errorText == "No speech detected in REC0034.wav")
        #expect(ImportJob.Phase.failedInternal("vault unwritable").errorText == "vault unwritable")
        #expect(ImportJob.Phase.handedOff.errorText == nil)
        #expect(ImportJob.Phase.cancelled.errorText == nil, "a user cancel is not an error row")
    }

    /// The cancel flag is readable from off the main actor — the offline pass
    /// polls it between chunks and cannot hop actors to do so.
    @Test func cancelIsVisibleThroughTheSharedTokenOffTheMainActor() async {
        let job = ImportJob(sourceURL: URL(fileURLWithPath: "/tmp/REC0034.wav"))
        let token = job.cancelToken
        #expect(await Task.detached { token.isCancelled }.value == false)
        job.cancel()
        #expect(await Task.detached { token.isCancelled }.value)
        #expect(job.isCancelRequested)
    }

    @Test func progressIsExactAndClamped() {
        let job = ImportJob(sourceURL: URL(fileURLWithPath: "/tmp/REC0034.wav"))
        job.updateProgress(framesConsumed: 24_000, totalFrames: 96_000)
        #expect(job.progressFraction == 0.25)
        job.updateProgress(framesConsumed: 200_000, totalFrames: 96_000)
        #expect(job.progressFraction == 1)
    }
}
