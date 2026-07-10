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

    private func makeHandle(id: String, fixture: Fixture, systemWAV: URL? = nil) -> SessionHandle {
        SessionHandle(
            id: id,
            sessionType: .callCapture,
            sourceApp: "Test",
            wavBufferPath: systemWAV,
            micWavPath: fixture.micWAV,
            micFirstSampleTime: fixture.snapshot.sessionStartTime,
            systemFirstSampleTime: nil,
            transcript: fixture.snapshot
        )
    }

    private func makeJob(_ handle: SessionHandle, retention: RecordingRetentionConfig? = nil) -> PostProcessingJob {
        PostProcessingJob(handle: handle, clusterThreshold: 0.7, numberOfSpeakers: 0, retention: retention, exportVoiceprints: false)
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

        let saved = try await job.run(using: ASRCoordinator())

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
                schema: SessionSidecar.currentSchema, sessionId: "j2",
                transcriptPath: fx.snapshot.filePath.path, startedAt: fx.snapshot.sessionStartTime,
                sourceApp: "Test", sessionType: .voiceMemo, sampleRate: 48_000,
                channels: 1, bitsPerSample: 32, appVersion: "test"
            ),
            to: SessionSidecar.sidecarURL(forWAV: fx.micWAV)
        )

        let keepFolder = fx.dir.appendingPathComponent("keep", isDirectory: true)
        let job = makeJob(makeHandle(id: "j2", fixture: fx), retention: RecordingRetentionConfig(folder: keepFolder))

        let saved = try await job.run(using: ASRCoordinator())

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
            schema: SessionSidecar.currentSchema, sessionId: "j4",
            transcriptPath: fx.snapshot.filePath.path,
            startedAt: fx.snapshot.sessionStartTime, sourceApp: "Test", sessionType: .callCapture,
            sampleRate: 48_000, channels: 1, bitsPerSample: 32, appVersion: "test"
        )
        try SessionSidecar.write(sidecar, to: SessionSidecar.sidecarURL(forWAV: systemWAV))

        // Failed retention keeps the sidecar on disk so the refresh is observable.
        let retention = RecordingRetentionConfig(folder: try unwritableFolder(in: fx.dir))
        let job = makeJob(makeHandle(id: "j4", fixture: fx, systemWAV: systemWAV), retention: retention)

        let saved = try await job.run(using: ASRCoordinator())

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
}
