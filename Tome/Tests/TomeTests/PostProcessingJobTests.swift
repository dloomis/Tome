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

    @Test func retentionSuccessExportsThenCleansUpIncludingRotatedSegments() async throws {
        let fx = try await makeFixture(id: "j2")
        defer { TestSupport.remove(fx.dir) }

        // A rotated pre-swap segment from a mid-session mic change.
        let rotated = try TestSupport.writeWAV(at: fx.dir.appendingPathComponent("j2.pre-111.mic.wav"), seconds: 1)

        let keepFolder = fx.dir.appendingPathComponent("keep", isDirectory: true)
        let job = makeJob(makeHandle(id: "j2", fixture: fx), retention: RecordingRetentionConfig(folder: keepFolder))

        let saved = try await job.run(using: ASRCoordinator())

        let kept = try FileManager.default.contentsOfDirectory(atPath: keepFolder.path).filter { $0.hasSuffix(".m4a") }
        #expect(kept.count == 1, "combined recording must exist, got \(kept)")
        #expect(!FileManager.default.fileExists(atPath: fx.micWAV.path), "verified success deletes the capture WAV")
        #expect(!FileManager.default.fileExists(atPath: rotated.path), "verified success deletes rotated segments")
        #expect(try String(contentsOf: saved, encoding: .utf8).contains("recording: \"[["),
                "transcript links to the retained audio")
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
