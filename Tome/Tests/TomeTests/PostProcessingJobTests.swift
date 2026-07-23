import Foundation
import Testing
@testable import Tome

/// The job's cleanup contract: capture WAVs are deleted ONLY after every step
/// that needs them has verifiably succeeded. These tests drive `run()` end to
/// end with diarization skipped (nil or nonexistent WAV path — `runDiarization`
/// bails on the existence check before touching any ML models), which exercises
/// the finalize → retention → cleanup spine for real.
@Suite @MainActor struct PostProcessingJobTests {

    private struct Fixture {
        let dir: URL          // stands in for the app-support sessions dir
        let vault: URL
        let micWAV: URL
        let snapshot: TranscriptSessionSnapshot
    }

    private func makeFixture(id: String, suggestedFilename: String? = nil) async throws -> Fixture {
        let dir = try TestSupport.makeTempDir()
        let vault = dir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let micWAV = try TestSupport.writeWAV(at: dir.appendingPathComponent("\(id).mic.wav"), seconds: 1)
        var snapshot = try await TestSupport.makeSessionNote(vault: vault)
        if let suggestedFilename {
            snapshot = TestSupport.snapshot(filePath: snapshot.filePath, suggestedFilename: suggestedFilename)
        }
        return Fixture(dir: dir, vault: vault, micWAV: micWAV, snapshot: snapshot)
    }

    private func makeHandle(id: String, fixture: Fixture, systemWAV: URL? = nil, sessionType: SessionType = .callCapture, snapshot: TranscriptSessionSnapshot? = nil) -> SessionHandle {
        SessionHandle(
            id: id,
            sessionType: sessionType,
            sourceApp: "Test",
            wavBufferPath: systemWAV,
            micWavPath: fixture.micWAV,
            micFirstSampleTime: fixture.snapshot.sessionStartTime,
            systemFirstSampleTime: nil,
            transcript: snapshot ?? fixture.snapshot
        )
    }

    private func makeJob(_ handle: SessionHandle, retention: RecordingRetentionConfig? = nil, discardIfShorterThanOrEqual: TimeInterval? = nil) -> PostProcessingJob {
        PostProcessingJob(handle: handle, clusterThreshold: 0.7, numberOfSpeakers: 0, retention: retention, exportVoiceprints: false, discardIfShorterThanOrEqual: discardIfShorterThanOrEqual)
    }

    /// Unwrap the saved-transcript URL out of a `JobOutcome`; a discard here is a
    /// test failure, not an alternate success.
    private func requireSaved(_ outcome: PostProcessingJob.JobOutcome) throws -> URL {
        guard case .saved(let url) = outcome else {
            throw NSError(domain: "PostProcessingJobTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "expected .saved, got \(outcome)"])
        }
        return url
    }

    /// A snapshot on the fixture's note whose start/end pin the session duration.
    private func snapshot(_ fx: Fixture, durationSeconds: TimeInterval) -> TranscriptSessionSnapshot {
        let end = Date()
        return TestSupport.snapshot(filePath: fx.snapshot.filePath, start: end.addingTimeInterval(-durationSeconds), end: end)
    }

    /// A folder path that `createDirectory` cannot create: nested under a file.
    private func unwritableFolder(in dir: URL) throws -> URL {
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        return blocker.appendingPathComponent("sub", isDirectory: true)
    }

    @Test func retentionFailurePreservesSourceAudio() async throws {
        let fx = try await makeFixture(id: "j1")
        defer { TestSupport.remove(fx.dir) }

        let retention = RecordingRetentionConfig(folder: try unwritableFolder(in: fx.dir))
        let job = makeJob(makeHandle(id: "j1", fixture: fx), retention: retention)

        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))

        #expect(FileManager.default.fileExists(atPath: saved.path), "transcript still finalizes")
        #expect(FileManager.default.fileExists(atPath: fx.micWAV.path),
                "a failed retention export must never delete the only copy of the audio")
    }

    @Test func retentionSuccessExportsThenCleansUpButKeepsUnmixedRotations() async throws {
        let fx = try await makeFixture(id: "j2")
        defer { TestSupport.remove(fx.dir) }

        // A rotated pre-swap segment from THIS session (timestamp after session
        // start). The mixer only reads the current-generation WAV, so this audio
        // is NOT in the exported .m4a — with retention on, deleting it would
        // silently drop the pre-swap audio the user asked to keep.
        let ownTs = UInt64((fx.snapshot.sessionStartTime.timeIntervalSince1970 + 1) * 1000)
        let rotated = try TestSupport.writeWAV(at: fx.dir.appendingPathComponent("j2.pre-\(ownTs).mic.wav"), seconds: 1)

        // Mic-only sessions emit a sidecar next to the mic WAV; success must remove it.
        try SessionSidecar.write(
            SessionSidecar(
                schema: SessionSidecar.currentSchema, sessionId: "j2", sessionGuid: "guid-j2",
                transcriptPath: fx.snapshot.filePath.path, startedAt: fx.snapshot.sessionStartTime,
                sourceApp: "Test", sessionType: .voiceMemo, sampleRate: 48_000,
                channels: 1, bitsPerSample: 32, appVersion: "test"
            ),
            to: SessionSidecar.sidecarURL(forWAV: fx.micWAV)
        )

        let keepFolder = fx.dir.appendingPathComponent("keep", isDirectory: true)
        let job = makeJob(makeHandle(id: "j2", fixture: fx), retention: RecordingRetentionConfig(folder: keepFolder))

        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))

        let kept = try FileManager.default.contentsOfDirectory(atPath: keepFolder.path).filter { $0.hasSuffix(".m4a") }
        #expect(kept.count == 1, "combined recording must exist, got \(kept)")
        #expect(!FileManager.default.fileExists(atPath: fx.micWAV.path), "verified success deletes the capture WAV")
        #expect(FileManager.default.fileExists(atPath: rotated.path),
                "with retention ON, an unmixed same-session rotation is kept — it holds audio absent from the export")
        #expect(!FileManager.default.fileExists(atPath: SessionSidecar.sidecarURL(forWAV: fx.micWAV).path),
                "verified success deletes the mic WAV's sidecar (mic-only sessions emit one)")
        #expect(try String(contentsOf: saved, encoding: .utf8).contains("recording: \"[["),
                "transcript links to the retained audio")
    }

    @Test func retentionOffCleanupRemovesOwnRotationsOnly() async throws {
        // With retention OFF the session's audio is discarded by design — its own
        // rotations go too. But a rotation stamped BEFORE this session started is
        // a PRIOR session's preserved audio (rotated aside when this session
        // claimed the path after that session failed to finalize) — this
        // session's success says nothing about it.
        let fx = try await makeFixture(id: "j7")
        defer { TestSupport.remove(fx.dir) }

        let ownTs = UInt64((fx.snapshot.sessionStartTime.timeIntervalSince1970 + 1) * 1000)
        let own = try TestSupport.writeWAV(at: fx.dir.appendingPathComponent("j7.pre-\(ownTs).mic.wav"), seconds: 1)
        let priorTs = UInt64((fx.snapshot.sessionStartTime.timeIntervalSince1970 - 3600) * 1000)
        let prior = try TestSupport.writeWAV(at: fx.dir.appendingPathComponent("j7.pre-\(priorTs).wav"), seconds: 1)

        let job = makeJob(makeHandle(id: "j7", fixture: fx))
        _ = try await job.run(using: ASRCoordinator())

        #expect(!FileManager.default.fileExists(atPath: own.path),
                "retention off: this session's rotations are discarded with its audio")
        #expect(FileManager.default.fileExists(atPath: prior.path),
                "a prior session's preserved (unfinalized) audio must survive this session's success")
    }

    @Test func deletedNoteIsRebuiltFromJSONLAndFinalized() async throws {
        // Incident 2026-07-23: the live note was deleted externally before the
        // job ran (nothing to relocate). With the session JSONL next to the
        // capture WAVs, the job must rebuild the note and finalize normally
        // instead of failing with markdownReadFailed.
        let fx = try await makeFixture(id: "j13")
        defer { TestSupport.remove(fx.dir) }

        // Pin the session length so finalization has a visible duration to write.
        let sessionSnap = snapshot(fx, durationSeconds: 65)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = SessionRecord(
            speaker: .you,
            text: "rebuilt from journal",
            timestamp: sessionSnap.sessionStartTime.addingTimeInterval(3)
        )
        try (String(decoding: try encoder.encode(record), as: UTF8.self) + "\n")
            .write(to: fx.dir.appendingPathComponent("j13.jsonl"), atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(at: fx.snapshot.filePath)
        let job = makeJob(makeHandle(id: "j13", fixture: fx, snapshot: sessionSnap))

        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))
        let content = try String(contentsOf: saved, encoding: .utf8)
        #expect(content.contains("rebuilt from journal"),
                "the note must be reconstructed from the session JSONL")
        #expect(content.contains("duration: \"01:05\""),
                "the rebuilt note must go through normal frontmatter finalization")
    }

    @Test func successCleansUpStaleFailureMarker() async throws {
        let fx = try await makeFixture(id: "j14")
        defer { TestSupport.remove(fx.dir) }

        // Marker left by an earlier failed run of the same session id.
        try Data("{}".utf8).write(to: JobFailureMarker.markerURL(forSessionId: "j14", in: fx.dir))

        let job = makeJob(makeHandle(id: "j14", fixture: fx))
        _ = try requireSaved(try await job.run(using: ASRCoordinator()))

        #expect(!FileManager.default.fileExists(atPath: JobFailureMarker.markerURL(forSessionId: "j14", in: fx.dir).path),
                "a verified success must remove the stale failure marker")
    }

    @Test func finalizeFailurePreservesSourceAudio() async throws {
        let fx = try await makeFixture(id: "j3")
        defer { TestSupport.remove(fx.dir) }

        // Vault note vanishes (unmount / user deletion) before the job runs.
        try FileManager.default.removeItem(at: fx.snapshot.filePath)
        let job = makeJob(makeHandle(id: "j3", fixture: fx))

        do {
            _ = try await job.run(using: ASRCoordinator())
            Issue.record("run must throw when the note is unreadable")
        } catch {
            guard case .markdownReadFailed = error else {
                Issue.record("expected markdownReadFailed, got \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: fx.micWAV.path),
                "a failed finalize must leave the audio for recovery")
    }

    @Test func renameRefreshesSidecarTranscriptPath() async throws {
        let fx = try await makeFixture(id: "j4", suggestedFilename: "Renamed Meeting")
        defer { TestSupport.remove(fx.dir) }

        // System WAV path that doesn't exist (skips diarization) but has a sidecar —
        // the crash-recovery pairing we must keep valid across the rename.
        let systemWAV = fx.dir.appendingPathComponent("j4.wav")
        let sidecar = SessionSidecar(
            schema: SessionSidecar.currentSchema, sessionId: "j4", sessionGuid: "guid-j4",
            transcriptPath: fx.snapshot.filePath.path,
            startedAt: fx.snapshot.sessionStartTime, sourceApp: "Test", sessionType: .callCapture,
            sampleRate: 48_000, channels: 1, bitsPerSample: 32, appVersion: "test"
        )
        try SessionSidecar.write(sidecar, to: SessionSidecar.sidecarURL(forWAV: systemWAV))

        // Failed retention keeps the sidecar on disk so the refresh is observable.
        let retention = RecordingRetentionConfig(folder: try unwritableFolder(in: fx.dir))
        let job = makeJob(makeHandle(id: "j4", fixture: fx, systemWAV: systemWAV), retention: retention)

        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))

        #expect(saved.lastPathComponent == "Renamed Meeting.md")
        let updated = try SessionSidecar.read(from: SessionSidecar.sidecarURL(forWAV: systemWAV))
        #expect(updated.transcriptPath == saved.path,
                "sidecar must follow the rename or auto-recovery reports 'transcript file missing'")
    }

    @Test func cancelledJobPreservesCaptureFiles() async throws {
        let fx = try await makeFixture(id: "j5")
        defer { TestSupport.remove(fx.dir) }

        let job = makeJob(makeHandle(id: "j5", fixture: fx))
        let task = Task { @MainActor in try await job.run(using: ASRCoordinator()) }
        task.cancel()  // lands before the main-actor task body can start

        do {
            _ = try await task.value
            Issue.record("expected .cancelled")
        } catch {
            guard case PostProcessingError.cancelled = error else {
                Issue.record("expected cancelled, got \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: fx.micWAV.path),
                "cancellation must leave the capture files for the orphan scan")
        #expect(FileManager.default.fileExists(atPath: fx.snapshot.filePath.path))
    }

    @Test func externallyRenamedNoteIsRelocatedAndNotRenamedBack() async throws {
        // The vault pipeline (WhisperCal) can retitle the live note before the
        // job runs — the snapshot path goes stale and every rewrite step would
        // fail markdownReadFailed. The job must follow the rename via the
        // preserved source_file: key (quotes stripped, as the external YAML
        // round-trip does), finalize in place, and KEEP the curated name.
        let fx = try await makeFixture(id: "j12", suggestedFilename: "Should Not Apply")
        defer { TestSupport.remove(fx.dir) }

        let originalName = fx.snapshot.filePath.lastPathComponent
        let renamed = fx.vault.appendingPathComponent("2026-07-10 1500 - Curated Title - Transcript.md")
        var content = try String(contentsOf: fx.snapshot.filePath, encoding: .utf8)
        content = content.replacingOccurrences(
            of: "source_file: \"\(originalName)\"",
            with: "source_file: \(originalName)"
        )
        try content.write(to: renamed, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fx.snapshot.filePath)

        let job = makeJob(makeHandle(id: "j12", fixture: fx))
        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))

        // Symlink-tolerant compare: the tempdir round-trips as /private/var vs /var.
        #expect(saved.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path,
                "job must finalize the renamed note in place, got \(saved.path)")
        let finalized = try String(contentsOf: renamed, encoding: .utf8)
        #expect(!finalized.contains("duration: \"00:00\""),
                "frontmatter finalization must land on the relocated note")
    }

    // MARK: - Short-session discard (AppSettings.discardShortMeetings)

    @Test func shortCallCaptureIsDiscardedWithAllItsFiles() async throws {
        let fx = try await makeFixture(id: "j8")
        defer { TestSupport.remove(fx.dir) }

        let systemWAV = try TestSupport.writeWAV(at: fx.dir.appendingPathComponent("j8.wav"), seconds: 1)
        let handle = makeHandle(id: "j8", fixture: fx, systemWAV: systemWAV,
                                snapshot: snapshot(fx, durationSeconds: 18))
        let job = makeJob(handle, discardIfShorterThanOrEqual: 30)

        let outcome = try await job.run(using: ASRCoordinator())

        guard case .discarded(let path, let durationSeconds) = outcome else {
            Issue.record("expected .discarded, got \(outcome)")
            return
        }
        #expect(path == fx.snapshot.filePath)
        #expect(durationSeconds == 18)
        #expect(!FileManager.default.fileExists(atPath: fx.snapshot.filePath.path),
                "the live transcript must not reach the vault")
        #expect(!FileManager.default.fileExists(atPath: systemWAV.path),
                "a discarded session keeps no capture audio")
        #expect(!FileManager.default.fileExists(atPath: fx.micWAV.path))
    }

    @Test func discardThresholdIsInclusiveAtTheBoundary() async throws {
        // Exactly at the threshold → discarded; one second over → saved.
        let atFx = try await makeFixture(id: "j9")
        defer { TestSupport.remove(atFx.dir) }
        let atJob = makeJob(makeHandle(id: "j9", fixture: atFx, snapshot: snapshot(atFx, durationSeconds: 30)),
                            discardIfShorterThanOrEqual: 30)
        guard case .discarded = try await atJob.run(using: ASRCoordinator()) else {
            Issue.record("a session of exactly the threshold length must be discarded")
            return
        }

        let overFx = try await makeFixture(id: "j10")
        defer { TestSupport.remove(overFx.dir) }
        let overJob = makeJob(makeHandle(id: "j10", fixture: overFx, snapshot: snapshot(overFx, durationSeconds: 31)),
                              discardIfShorterThanOrEqual: 30)
        let saved = try requireSaved(try await overJob.run(using: ASRCoordinator()))
        #expect(FileManager.default.fileExists(atPath: saved.path),
                "a session over the threshold is saved normally")
    }

    @Test func voiceMemoIsNeverDiscarded() async throws {
        // The caller only passes a threshold for call captures; the job backstops
        // that policy — a short voice memo is deliberate and must survive even if
        // a threshold slips through.
        let fx = try await makeFixture(id: "j11")
        defer { TestSupport.remove(fx.dir) }
        let handle = makeHandle(id: "j11", fixture: fx, sessionType: .voiceMemo,
                                snapshot: snapshot(fx, durationSeconds: 5))
        let job = makeJob(handle, discardIfShorterThanOrEqual: 30)

        let saved = try requireSaved(try await job.run(using: ASRCoordinator()))
        #expect(FileManager.default.fileExists(atPath: saved.path),
                "a 5s voice memo must be saved, never discarded")
    }
}
