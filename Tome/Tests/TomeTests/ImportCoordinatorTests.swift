@preconcurrency import AVFoundation
import Foundation
import os
import Testing
@testable import Tome

// MARK: - Seams

/// Everything the scripted pass is handed, boxed so a test body can emit
/// utterances, watch progress, and observe the cancel flag.
private struct PassContext: Sendable {
    let fileURL: URL
    let baseTime: Date
    let isCancelled: @Sendable () -> Bool
    let onProgress: @Sendable (Int64, Int64) -> Void
    let emit: @Sendable (String, Date) async -> Void
}

/// Scripted stand-in for `StreamingImportPass` — the `VADStream` precedent, one
/// level up. No models, no audio decode: the coordinator's artifact/rollback/
/// gating logic is what's under test.
private final class ScriptedPass: ImportLivePass {
    private struct Call: Sendable {
        let url: URL
        let baseTime: Date
    }

    private struct State {
        var calls: [Call] = []
        var concurrent = 0
        var maxConcurrent = 0
    }

    private let body: @Sendable (PassContext) async -> ImportPassOutcome
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ body: @escaping @Sendable (PassContext) async -> ImportPassOutcome) {
        self.body = body
    }

    /// Convenience: emit `texts` at 1s spacing from the recording start, then end.
    static func emitting(_ texts: [String], outcome: ImportPassOutcome = .completed) -> ScriptedPass {
        ScriptedPass { context in
            for (index, text) in texts.enumerated() {
                await context.emit(text, context.baseTime.addingTimeInterval(Double(index)))
            }
            return outcome
        }
    }

    func run(
        fileURL: URL,
        baseTime: Date,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onUtterance: @escaping @Sendable (String, Date) async -> Void
    ) async -> ImportPassOutcome {
        state.withLock {
            $0.calls.append(Call(url: fileURL, baseTime: baseTime))
            $0.concurrent += 1
            $0.maxConcurrent = max($0.maxConcurrent, $0.concurrent)
        }
        defer { state.withLock { $0.concurrent -= 1 } }
        return await body(PassContext(
            fileURL: fileURL,
            baseTime: baseTime,
            isCancelled: isCancelled,
            onProgress: onProgress,
            emit: onUtterance
        ))
    }

    var callCount: Int { state.withLock { $0.calls.count } }
    var baseTimes: [Date] { state.withLock { $0.calls.map(\.baseTime) } }
    var readURLs: [URL] { state.withLock { $0.calls.map(\.url) } }
    var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
}

/// Per-key rendezvous so a test can hold a pass inside `run` and release it
/// deterministically (no sleeps, no ordering luck).
private actor GateBoard {
    private var opened: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ key: String) async {
        if opened.contains(key) { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func open(_ key: String) {
        opened.insert(key)
        for continuation in waiters.removeValue(forKey: key) ?? [] { continuation.resume() }
    }
}

/// Temp sessions dir + temp vault + a coordinator wired to both.
@MainActor
private final class Harness {
    let root: URL
    let sessions: URL
    let vault: URL
    var idle = true
    private(set) var enqueued: [PostProcessingJob] = []
    let coordinator: ImportCoordinator

    init(pass: any ImportLivePass, vaultPathOverride: String? = nil, sessionsAvailable: Bool = true) throws {
        root = try TestSupport.makeTempDir()
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let sessionsDir = sessions
        let vaultDir = vault
        let configuredVaultPath = vaultPathOverride ?? vault.path
        // Box the mutable bits so the closures don't capture `self` before init
        // completes; the harness reads them back through the same box.
        let idleBox = IdleBox()
        let sink = JobSink()
        self.idleBox = idleBox
        self.sink = sink
        coordinator = ImportCoordinator(
            pass: pass,
            environment: {
                ImportEnvironment(
                    sessionsDirectory: sessionsAvailable ? sessionsDir : nil,
                    vaultPath: configuredVaultPath,
                    filenameDateFormat: "yyyy-MM-dd HH-mm-ss",
                    filenameTypeLabel: "Voice Memo",
                    protectedDirectories: [sessionsDir, vaultDir],
                    postProcessing: ImportPostProcessingOptions(clusterThreshold: 0.7, numberOfSpeakers: 0)
                )
            },
            isIdle: { idleBox.idle },
            enqueuePostProcessing: { sink.jobs.append($0) },
            // Pokes drive the drain in these tests; the backstop poll must never
            // fire and make an assertion depend on timing.
            idleRetryInterval: .seconds(600)
        )
        idleBox.idle = true
    }

    @MainActor final class IdleBox { var idle = true }
    @MainActor final class JobSink { var jobs: [PostProcessingJob] = [] }
    private let idleBox: IdleBox
    private let sink: JobSink

    var handedOffJobs: [PostProcessingJob] { sink.jobs }

    func setIdle(_ value: Bool) {
        idleBox.idle = value
        coordinator.sessionStateDidChange()
    }

    /// Sets idle WITHOUT poking — for proving a start decision is made on the
    /// probe's current value rather than on a stale cached one.
    func setIdleSilently(_ value: Bool) {
        idleBox.idle = value
    }

    func cleanup() { TestSupport.remove(root) }

    // MARK: fixtures

    @discardableResult
    func makeSourceWAV(_ name: String, seconds: Double = 2.0, created: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestSupport.writeWAV(at: url, seconds: seconds)
        if let created {
            try FileManager.default.setAttributes(
                [.creationDate: created, .modificationDate: created],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    func contents(of directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    /// Poll on the main actor until `condition` holds. Everything the coordinator
    /// does lands on this actor, so a sleep here is a genuine yield.
    func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitUntilFinished() async throws {
        try await waitFor("the import queue to drain") { self.coordinator.activeJob == nil }
    }
}

// MARK: - Tests

@Suite @MainActor struct ImportCoordinatorTests {

    // MARK: Zero speech

    /// §6.1: a silent import is a mistake, not a memo. Nothing may survive it —
    /// not the note, not the JSONL, not the WAV copy, not the sidecar — and no
    /// post-processing job may be enqueued.
    @Test func silentImportRollsBackEverythingAndReportsNoSpeech() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting([]))
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failed(.noSpeech(filename: "REC0034.wav")))
        #expect(harness.handedOffJobs.isEmpty, "a silent import must not reach post-processing")
        #expect(harness.coordinator.results.last?.outcome == .failed("No speech detected in REC0034.wav"))
        #expect(job.artifacts.isEmpty, "the rollback list must be emptied once unwound")
        #expect(FileManager.default.fileExists(atPath: source.path), "the user's original file is never touched")
    }

    /// Rollback-list completeness, proven by directory diff rather than by
    /// enumerating the paths the implementation happens to know about.
    @Test func rollbackLeavesNoTraceInTheSessionsDirectoryOrTheVault() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting([]))
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        let sessionsBefore = harness.contents(of: harness.sessions)
        let vaultBefore = harness.contents(of: harness.vault)

        harness.coordinator.enqueue([source])
        try await harness.waitUntilFinished()

        #expect(harness.contents(of: harness.sessions) == sessionsBefore,
                "sessions directory changed: \(harness.contents(of: harness.sessions))")
        #expect(harness.contents(of: harness.vault) == vaultBefore,
                "vault changed: \(harness.contents(of: harness.vault))")
    }

    // MARK: Partial transcripts survive

    /// The inversion this whole spot exists to prevent. The pass breaks mid-file
    /// AFTER committing text: every artifact stays, and the session is handed off
    /// so the ordinary pipeline (and its orphan / `.failed.json` nets) can finish
    /// or recover it.
    @Test func midPassReadFailureKeepsThePartialTranscriptAndHandsItOff() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["first line", "second line"], outcome: .readFailed("I/O error at frame 900")))
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .handedOff)
        #expect(harness.handedOffJobs.count == 1)

        let handle = try #require(harness.handedOffJobs.first?.handle)
        let note = handle.transcript.filePath
        #expect(FileManager.default.fileExists(atPath: note.path), "the partial note must survive")
        let body = try String(contentsOf: note, encoding: .utf8)
        #expect(body.contains("first line"))
        #expect(body.contains("second line"))

        let micWav = try #require(handle.micWavPath)
        #expect(FileManager.default.fileExists(atPath: micWav.path), "the WAV copy must survive")
        #expect(FileManager.default.fileExists(atPath: SessionSidecar.sidecarURL(forWAV: micWav).path))
        let jsonl = try #require(handle.jsonlURL)
        #expect(FileManager.default.fileExists(atPath: jsonl.path))
        let journal = try String(contentsOf: jsonl, encoding: .utf8)
        #expect(journal.contains("first line") && journal.contains("second line"),
                "the crash-recovery journal must carry the same utterances as the note")
    }

    /// A cancel after text has landed follows the same rule: keep and hand off.
    /// Discarding here would destroy work the user can't get back, and the user
    /// asked to stop transcribing — not to shred what was already transcribed.
    @Test func cancelAfterPartialTranscriptKeepsItAndHandsItOff() async throws {
        let gates = GateBoard()
        let pass = ScriptedPass { context in
            await context.emit("already transcribed", context.baseTime)
            await gates.wait("cancel-requested")
            return context.isCancelled() ? .cancelled : .completed
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitFor("the pass to start") { pass.callCount == 1 }
        harness.coordinator.cancelActiveJob()
        await gates.open("cancel-requested")
        try await harness.waitUntilFinished()

        #expect(job.phase == .handedOff)
        #expect(harness.handedOffJobs.count == 1)
        #expect(job.isCancelRequested, "the cancel was honored — it just didn't destroy anything")
    }

    /// A cancel before anything landed unwinds completely and reports nothing:
    /// the user asked for it, so it isn't an error row.
    @Test func cancelBeforeAnyUtteranceRollsBackAndIsNotReportedAsAFailure() async throws {
        let gates = GateBoard()
        let pass = ScriptedPass { context in
            await gates.wait("cancel-requested")
            return context.isCancelled() ? .cancelled : .completed
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        let sessionsBefore = harness.contents(of: harness.sessions)
        let vaultBefore = harness.contents(of: harness.vault)

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitFor("the pass to start") { pass.callCount == 1 }
        harness.coordinator.cancelActiveJob()
        await gates.open("cancel-requested")
        try await harness.waitUntilFinished()

        #expect(job.phase == .cancelled)
        #expect(harness.coordinator.results.last?.outcome == .cancelled)
        #expect(harness.coordinator.results.last?.message == nil)
        #expect(harness.handedOffJobs.isEmpty)
        #expect(harness.contents(of: harness.sessions) == sessionsBefore)
        #expect(harness.contents(of: harness.vault) == vaultBefore)
    }

    /// Cancel-all must never *start* a job. Regression: routing queued jobs
    /// through `cancel(_:)` called `startNextIfPossible` between removals, which
    /// could promote a later queued job to active moments before its own cancel
    /// landed — here, the app went idle without a poke, so that promotion was
    /// exactly what a cancel-all would have triggered.
    @Test func cancelAllNeverStartsAQueuedJob() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        harness.setIdleSilently(false)
        let first = try harness.makeSourceWAV("A.wav")
        let second = try harness.makeSourceWAV("B.wav")

        harness.coordinator.enqueue([first, second])
        #expect(harness.coordinator.pendingJobs.count == 2)

        // The app is idle again, but nothing has poked the coordinator yet.
        harness.setIdleSilently(true)
        harness.coordinator.cancelAll()

        #expect(harness.coordinator.activeJob == nil, "cancel-all promoted a job it was cancelling")
        #expect(harness.coordinator.pendingJobs.isEmpty)
        #expect(harness.coordinator.results.count == 2)
        #expect(harness.coordinator.results.allSatisfy { $0.outcome == .cancelled })

        try await Task.sleep(for: .milliseconds(30))
        #expect(pass.callCount == 0, "a cancelled job ran anyway")
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)
    }

    /// Cancelling a job that hasn't started drops it from the queue without
    /// creating (or unwinding) anything.
    @Test func cancellingAQueuedJobDropsItWithoutRunningIt() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        harness.setIdleSilently(false)
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.pendingJobs.first)
        harness.coordinator.cancel(job)

        #expect(harness.coordinator.pendingJobs.isEmpty)
        #expect(job.phase == .cancelled)
        harness.setIdle(true)
        try await harness.waitUntilFinished()
        #expect(pass.callCount == 0, "a cancelled queue entry must not run when the app goes idle")
    }

    // MARK: Hand-off shape

    @Test func handoffCarriesTheImportedOriginAndTheBackdatedRecordingWindow() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["hello from the field recorder"]))
        defer { harness.cleanup() }
        let recordedAt = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15, well in the past
        let source = try harness.makeSourceWAV("REC0034.wav", seconds: 3.0, created: recordedAt)
        let duration = try TestSupport.wavDuration(source)

        harness.coordinator.enqueue([source])
        try await harness.waitUntilFinished()

        let job = try #require(harness.handedOffJobs.first)
        let handle = job.handle
        #expect(handle.origin == .imported)
        #expect(handle.sessionType == .voiceMemo)
        #expect(handle.sourceApp == "Imported")
        #expect(handle.wavBufferPath == nil, "imports are mic-only — there is no system leg")
        #expect(handle.micWavPath?.lastPathComponent == "\(handle.id).mic.wav")
        #expect(handle.voiceprintIncludesYou == false,
                "Tome cannot attest the user is among the speakers of a file recorded elsewhere")

        #expect(handle.transcript.sessionStartTime == recordedAt)
        #expect(abs(handle.transcript.sessionEndTime.timeIntervalSince(recordedAt) - duration) < 0.001)
        #expect(handle.micFirstSampleTime == recordedAt,
                "retention alignment pads from the session start — an offset here would prepend silence")
        #expect(handle.transcript.sessionContext == "REC0034",
                "the finalized filename's human hook to the source recording")

        // The live note is dated to the recording, not to the import.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let prefix = formatter.string(from: recordedAt)
        #expect(handle.transcript.filePath.lastPathComponent == "\(prefix) Voice Memo.md")

        // Post-processing must never discard a memo for being short.
        #expect(job.discardIfShorterThanOrEqual == nil)
    }

    /// Import ids live in their own namespace: a live session minted in the same
    /// wall-clock second uses `SessionStore.generateSessionId()` verbatim, so an
    /// id carrying the `-import` marker can never collide with it — the engine
    /// would otherwise overwrite the import's WAV copy and interleave both
    /// sessions into one JSONL.
    @Test func importSessionIdsCannotCollideWithALiveSessionsId() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["hello"]))
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        try await harness.waitUntilFinished()

        let handle = try #require(harness.handedOffJobs.first?.handle)
        #expect(handle.id.contains("-import"), "import id \(handle.id) is minted in the live namespace")
        #expect(handle.id != SessionStore.generateSessionId())
    }

    /// A pass that ends early (cancel, read failure) with text landed must stamp
    /// the recording window at the last consumed frame — stamping the full audio
    /// length would claim untranscribed minutes as covered in `duration:`.
    @Test func aPartialHandOffStampsTheEndAtTheLastConsumedFrame() async throws {
        let pass = ScriptedPass { context in
            // Half of the 2s / 48kHz fixture was consumed before the failure.
            context.onProgress(48_000, 96_000)
            await context.emit("first line", context.baseTime)
            return .readFailed("I/O error mid-file")
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let recordedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let source = try harness.makeSourceWAV("REC0034.wav", seconds: 2.0, created: recordedAt)

        harness.coordinator.enqueue([source])
        try await harness.waitUntilFinished()

        let handle = try #require(harness.handedOffJobs.first?.handle)
        #expect(handle.transcript.sessionStartTime == recordedAt)
        #expect(abs(handle.transcript.sessionEndTime.timeIntervalSince(recordedAt) - 1.0) < 0.001,
                "expected the window to end at the last consumed frame (1s), got \(handle.transcript.sessionEndTime.timeIntervalSince(recordedAt))s")
    }

    /// The pass reads Tome's copy in the sessions directory, never the user's
    /// file (§5.5) — a source on removable media can vanish mid-import.
    @Test func theOfflinePassReadsTomesCopyNotTheOriginal() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        try await harness.waitUntilFinished()

        let read = try #require(pass.readURLs.first)
        #expect(read != source)
        #expect(read.deletingLastPathComponent().standardizedFileURL == harness.sessions.standardizedFileURL)
        #expect(read.lastPathComponent.hasSuffix(".mic.wav"))
    }

    // MARK: Validation gates

    @Test func aNonWAVIsRejectedAtIntakeAndNeverBecomesAJob() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["hello"]))
        defer { harness.cleanup() }
        let notes = harness.root.appendingPathComponent("notes.txt")
        try "not audio".write(to: notes, atomically: true, encoding: .utf8)

        harness.coordinator.enqueue([notes])

        #expect(harness.coordinator.pendingJobs.isEmpty)
        #expect(harness.coordinator.activeJob == nil)
        #expect(harness.coordinator.results.last?.outcome == .failed("Couldn't import notes.txt: not a WAV file"))
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)
    }

    @Test func aSubFloorRecordingFailsValidationBeforeAnythingIsCreated() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("blip.wav", seconds: 0.4)

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failed(.tooShort(filename: "blip.wav")))
        #expect(pass.callCount == 0, "validation must fail before the offline pass runs")
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)
        #expect(harness.handedOffJobs.isEmpty)
    }

    @Test func aTomeArtifactDroppedBackOntoTomeIsRefused() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["hello"]))
        defer { harness.cleanup() }
        let inside = harness.sessions.appendingPathComponent("session_2026-08-08_10-00-00.mic.wav")
        try TestSupport.writeWAV(at: inside, seconds: 2.0)

        harness.coordinator.enqueue([inside])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failed(.selfImport(filename: inside.lastPathComponent)))
        #expect(harness.contents(of: harness.sessions) == [inside.lastPathComponent],
                "the refused file is left exactly as it was, and nothing else was created")
        #expect(harness.contents(of: harness.vault).isEmpty)
    }

    @Test func aRenamedNonAudioFileDiesAtTheDecodeGate() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["hello"]))
        defer { harness.cleanup() }
        let fake = harness.root.appendingPathComponent("photo.wav")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: fake)

        harness.coordinator.enqueue([fake])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failed(.notReadable(filename: "photo.wav")))
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)
    }

    @Test func importIsRefusedWhenNoVoiceMemoFolderIsConfigured() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass, vaultPathOverride: "")
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failedInternal("Choose a voice-memo folder in Settings ▸ Output before importing"))
        #expect(pass.callCount == 0)
        #expect(harness.contents(of: harness.sessions).isEmpty, "nothing may be written without a destination")
        #expect(harness.handedOffJobs.isEmpty)
    }

    /// An unusable sessions directory refuses the import outright. A temp-dir
    /// fallback would write the WAV copy and crash-recovery artifacts somewhere
    /// the orphan scan never looks, making an interrupted import unrecoverable.
    @Test func importIsRefusedWhenTheSessionsDirectoryIsUnavailable() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass, sessionsAvailable: false)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()

        #expect(job.phase == .failedInternal("Tome's sessions folder isn't available — check that Application Support is writable"))
        #expect(pass.callCount == 0)
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)
        #expect(harness.handedOffJobs.isEmpty)
    }

    // MARK: Gating (§7)

    /// Enqueueing while a session is live is allowed — the file waits.
    @Test func enqueueingWhileRecordingWaitsInsteadOfStarting() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        harness.setIdleSilently(false)
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])

        #expect(harness.coordinator.activeJob == nil)
        #expect(harness.coordinator.pendingJobs.count == 1)
        #expect(harness.coordinator.isWaitingForIdle)
        #expect(harness.coordinator.isImporting == false)

        // Nothing may be created while it waits — not even the WAV copy.
        try await Task.sleep(for: .milliseconds(30))
        #expect(pass.callCount == 0)
        #expect(harness.contents(of: harness.sessions).isEmpty)
        #expect(harness.contents(of: harness.vault).isEmpty)

        harness.setIdle(true)
        try await harness.waitUntilFinished()
        #expect(pass.callCount == 1)
        #expect(harness.handedOffJobs.count == 1)
    }

    /// The pending window (`AppServices.isSessionPending`) is part of the probe:
    /// a start that has not yet flipped `isRecording` still blocks an import.
    @Test func thePendingWindowAloneIsEnoughToHoldAnImport() async throws {
        let pass = ScriptedPass.emitting(["hello"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        // Simulates `isSessionPending = true` with `activeSessionType` still nil.
        harness.setIdleSilently(false)
        harness.coordinator.enqueue([source])
        #expect(harness.coordinator.activeJob == nil)

        // …and the poke that follows the window closing starts it.
        harness.setIdle(true)
        try await harness.waitUntilFinished()
        #expect(pass.callCount == 1)
    }

    /// §7's second rule: a recording that starts while an import is running does
    /// NOT cancel it. The two serialize through the shared `ASRCoordinator`.
    @Test func aRecordingStartedMidImportDoesNotCancelTheImport() async throws {
        let gates = GateBoard()
        let pass = ScriptedPass { context in
            await context.emit("mid-import utterance", context.baseTime)
            await gates.wait("recording-started")
            return context.isCancelled() ? .cancelled : .completed
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitFor("the pass to start") { pass.callCount == 1 }

        // A live session begins mid-pass.
        harness.setIdle(false)
        #expect(harness.coordinator.activeJob === job, "the in-flight import must survive a session start")
        #expect(job.isCancelRequested == false)

        await gates.open("recording-started")
        try await harness.waitUntilFinished()
        #expect(job.phase == .handedOff)
        #expect(harness.handedOffJobs.count == 1)
    }

    /// …but the NEXT file waits until the app is idle again.
    @Test func theNextQueuedFileWaitsWhileTheAppIsBusy() async throws {
        let gates = GateBoard()
        let pass = ScriptedPass { context in
            await context.emit("line", context.baseTime)
            await gates.wait(context.fileURL.lastPathComponent)
            return .completed
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let first = try harness.makeSourceWAV("A.wav")
        let second = try harness.makeSourceWAV("B.wav")

        harness.coordinator.enqueue([first, second])
        try await harness.waitFor("the first pass to start") { pass.callCount == 1 }

        // Recording starts while file 1 is transcribing, then file 1 finishes.
        harness.setIdle(false)
        let firstCopy = try #require(pass.readURLs.first)
        await gates.open(firstCopy.lastPathComponent)

        try await harness.waitFor("file 1 to hand off") { harness.handedOffJobs.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(pass.callCount == 1, "file 2 must not start while a session is live")
        #expect(harness.coordinator.pendingJobs.count == 1)
        #expect(harness.coordinator.activeJob == nil)

        harness.setIdle(true)
        try await harness.waitFor("the second pass to start") { pass.callCount == 2 }
        let secondCopy = try #require(pass.readURLs.last)
        await gates.open(secondCopy.lastPathComponent)
        try await harness.waitUntilFinished()
        #expect(harness.handedOffJobs.count == 2)
    }

    // MARK: Serial drain (v2 semantics, tested now)

    @Test func aMultiFileEnqueueDrainsSeriallyInOrder() async throws {
        let pass = ScriptedPass.emitting(["line"])
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }

        // Distinct recording dates make the processing order observable through
        // the per-file backdated anchor.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try harness.makeSourceWAV("A.wav", created: base)
        let second = try harness.makeSourceWAV("B.wav", created: base.addingTimeInterval(3_600))
        let third = try harness.makeSourceWAV("C.wav", created: base.addingTimeInterval(7_200))

        harness.coordinator.enqueue([first, second, third])
        try await harness.waitUntilFinished()

        #expect(pass.maxConcurrent == 1, "the import stage is strictly serial")
        #expect(pass.baseTimes == [base, base.addingTimeInterval(3_600), base.addingTimeInterval(7_200)],
                "files must process in the order given, each with its own derived timestamps")
        #expect(harness.handedOffJobs.count == 3)
        #expect(Set(harness.handedOffJobs.map(\.handle.id)).count == 3,
                "each import gets its own session identity — no shared WAV/JSONL stem")
        #expect(harness.coordinator.results.count == 3)
        #expect(harness.coordinator.results.filter(\.isSuccess).count == 3)
    }

    /// Two imports started within the same second must not share a session stem
    /// (ids are second-resolution): the second would silently overwrite the
    /// first's WAV copy and journal.
    @Test func backToBackImportsGetDistinctSessionStems() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["line"]))
        defer { harness.cleanup() }
        let first = try harness.makeSourceWAV("A.wav")
        let second = try harness.makeSourceWAV("B.wav")

        harness.coordinator.enqueue([first, second])
        try await harness.waitUntilFinished()

        let ids = harness.handedOffJobs.map(\.handle.id)
        #expect(Set(ids).count == 2, "colliding session ids: \(ids)")
        let wavs = harness.handedOffJobs.compactMap(\.handle.micWavPath)
        #expect(wavs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// A failing file must not take the queue down with it (§9 failure isolation).
    @Test func oneBadFileDoesNotStopTheRest() async throws {
        let harness = try Harness(pass: ScriptedPass.emitting(["line"]))
        defer { harness.cleanup() }
        let good = try harness.makeSourceWAV("good.wav")
        let short = try harness.makeSourceWAV("short.wav", seconds: 0.4)
        let alsoGood = try harness.makeSourceWAV("also-good.wav")

        harness.coordinator.enqueue([good, short, alsoGood])
        try await harness.waitUntilFinished()

        #expect(harness.handedOffJobs.count == 2)
        #expect(harness.coordinator.results.count == 3)
        #expect(harness.coordinator.results.map(\.isSuccess) == [true, false, true])
    }

    // MARK: Progress

    @Test func progressIsReportedOntoTheJob() async throws {
        let pass = ScriptedPass { context in
            context.onProgress(48_000, 96_000)
            await context.emit("line", context.baseTime)
            context.onProgress(96_000, 96_000)
            return .completed
        }
        let harness = try Harness(pass: pass)
        defer { harness.cleanup() }
        let source = try harness.makeSourceWAV("REC0034.wav")

        harness.coordinator.enqueue([source])
        let job = try #require(harness.coordinator.activeJob)
        try await harness.waitUntilFinished()
        try await harness.waitFor("the final progress hop") { job.progressFraction == 1 }

        #expect(job.framesConsumed == 96_000)
        #expect(job.totalFrames == 96_000)
    }
}

// MARK: - Production pass

/// Scripted VAD — the same seam `StreamingTranscriberTests` uses, so the real
/// `FileAudioReader → StreamingTranscriber` wiring can run with no silero model.
private struct ScriptedVAD: VADStream {
    let events: [Int: VADEvent]
    var chunkIndex = 0

    mutating func process(_ chunk: [Float]) async throws -> VADEvent? {
        defer { chunkIndex += 1 }
        return events[chunkIndex]
    }
}

/// `StreamingImportPass` itself: the wiring the scripted-pass tests above stub
/// out. Real reader, real transcriber, fake VAD + fake ASR backend.
@Suite struct StreamingImportPassTests {

    private func makePass(
        events: [Int: VADEvent] = [0: .speechStart],
        vadError: Bool = false
    ) async -> StreamingImportPass {
        let coordinator = ASRCoordinator()
        await coordinator.install(backend: FakeBackend(model: .parakeetTDTv3), token: 1)
        return StreamingImportPass(asr: coordinator, makeVAD: {
            if vadError { throw FakeBackend.FakeError(message: "no VAD model") }
            return ScriptedVAD(events: events)
        })
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [(String, Date)] = []
        private var _frames: Int64 = 0
        func add(_ text: String, _ at: Date) { lock.withLock { _texts.append((text, at)) } }
        func progress(_ frames: Int64) { lock.withLock { _frames = max(_frames, frames) } }
        var texts: [(String, Date)] { lock.withLock { _texts } }
        var frames: Int64 { lock.withLock { _frames } }
    }

    /// End-to-end through the real transcriber: the file is read, segmented and
    /// committed, and the utterance is stamped from the *recording* start.
    @Test func transcribesAFileAndAnchorsUtterancesAtTheRecordingStart() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("copy.mic.wav"), seconds: 3.0)

        let pass = await makePass()
        let collected = Collected()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let outcome = await pass.run(
            fileURL: wav,
            baseTime: recordedAt,
            isCancelled: { false },
            onProgress: { consumed, _ in collected.progress(consumed) },
            onUtterance: { text, at in collected.add(text, at) }
        )

        #expect(outcome == .completed)
        #expect(collected.texts.map(\.0) == ["fake:parakeet-tdt-v3"])
        let stamp = try #require(collected.texts.first?.1)
        #expect(stamp >= recordedAt && stamp.timeIntervalSince(recordedAt) < 3.0,
                "utterance timestamps must describe audio position, not replay time")
        #expect(collected.frames == 144_000, "the whole 3s @ 48kHz file must be consumed")
    }

    /// A cancel stops the pass feeding audio at the next chunk boundary — it
    /// does not read the rest of the file first.
    @Test func aCancelStopsFeedingAtTheNextChunkInsteadOfDrainingTheFile() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("copy.mic.wav"), seconds: 10.0)

        let pass = await makePass()
        let collected = Collected()
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let outcome = await pass.run(
            fileURL: wav,
            baseTime: Date(),
            isCancelled: { cancelled.withLock { $0 } },
            // Cancel as soon as the first chunk lands.
            onProgress: { consumed, _ in
                collected.progress(consumed)
                cancelled.withLock { $0 = true }
            },
            onUtterance: { text, at in collected.add(text, at) }
        )

        #expect(outcome == .cancelled)
        // `AVAudioFile.read` may return slightly fewer frames than asked for,
        // so assert the shape, not an exact count: one ~0.5s chunk out of 10s.
        #expect(collected.frames > 0 && collected.frames <= 24_000,
                "expected about one 0.5s chunk from a 10s file — got \(collected.frames) frames")
        #expect(collected.frames * 4 < 480_000,
                "the pass kept reading after the cancel — \(collected.frames) of 480000 frames")
    }

    @Test func anUndecodableFileIsReportedAsARead() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let fake = dir.appendingPathComponent("copy.mic.wav")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: fake)

        let pass = await makePass()
        let outcome = await pass.run(
            fileURL: fake, baseTime: Date(), isCancelled: { false },
            onProgress: { _, _ in }, onUtterance: { _, _ in }
        )
        if case .readFailed = outcome {} else {
            Issue.record("expected .readFailed, got \(outcome)")
        }
    }

    /// A missing VAD is an engine problem, never "your recording is broken" —
    /// the distinction is what keeps the §8 report honest.
    @Test func anUnavailableVADIsReportedAsAnEngineFailureNotABadFile() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("copy.mic.wav"), seconds: 2.0)

        let pass = await makePass(vadError: true)
        let outcome = await pass.run(
            fileURL: wav, baseTime: Date(), isCancelled: { false },
            onProgress: { _, _ in }, onUtterance: { _, _ in }
        )
        if case .engineFailed = outcome {} else {
            Issue.record("expected .engineFailed, got \(outcome)")
        }
    }
}
