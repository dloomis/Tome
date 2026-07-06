import Foundation
import Testing
@testable import Tome

/// A failed job must be observable — the old queue logged and moved on, so the
/// user believed the transcript finalized and the API lifecycle stuck in
/// `transcribing` forever.
@Suite @MainActor struct PostProcessingQueueTests {

    @Test func failedJobPublishesLastFailure() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let vault = dir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let snapshot = try await TestSupport.makeSessionNote(vault: vault)
        // The note vanishes before the job runs → finalize throws markdownReadFailed.
        try FileManager.default.removeItem(at: snapshot.filePath)

        let handle = SessionHandle(
            id: "qfail-1",
            sessionType: .voiceMemo,
            sourceApp: "Test",
            wavBufferPath: nil,
            micWavPath: nil,
            micFirstSampleTime: nil,
            systemFirstSampleTime: nil,
            transcript: snapshot
        )
        let job = PostProcessingJob(handle: handle, clusterThreshold: 0.7, numberOfSpeakers: 0)

        let queue = PostProcessingQueue(asr: ASRCoordinator())
        queue.enqueue(job)

        // Poll for the published failure (consumer runs as a MainActor task).
        var failure: PostProcessingQueue.JobFailure?
        for _ in 0..<100 {
            if let f = queue.lastFailure { failure = f; break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let f = try #require(failure, "queue must publish the failure, not just log it")
        #expect(f.jobId == "qfail-1")
        #expect(!f.message.isEmpty)
        #expect(f.sessionType == .voiceMemo)
        #expect(queue.lastCompletion == nil, "a failed job must not look like a completion")
    }

    @Test func consecutiveIdenticalFailuresAreDistinctEvents() async throws {
        // ContentView observes lastFailure via onChange, which fires only when
        // the VALUE changes. Session ids are second-granular and reusable by API
        // callers — two failures with the same id and message must still compare
        // unequal, or the second one is invisible: no notification, and the API
        // lifecycle stuck in `transcribing` forever.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let vault = dir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        func failingJob() -> PostProcessingJob {
            // Identical failure identity on purpose: same id, same missing note.
            let snap = TestSupport.snapshot(filePath: vault.appendingPathComponent("gone.md"))
            let handle = SessionHandle(
                id: "dup", sessionType: .voiceMemo, sourceApp: "T",
                wavBufferPath: nil, micWavPath: nil, micFirstSampleTime: nil,
                systemFirstSampleTime: nil, transcript: snap
            )
            return PostProcessingJob(handle: handle, clusterThreshold: 0.7, numberOfSpeakers: 0)
        }

        let queue = PostProcessingQueue(asr: ASRCoordinator())
        queue.enqueue(failingJob())
        var first: PostProcessingQueue.JobFailure?
        for _ in 0..<100 {
            if let f = queue.lastFailure { first = f; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let f1 = try #require(first)

        queue.enqueue(failingJob())
        var second: PostProcessingQueue.JobFailure?
        for _ in 0..<100 {
            if let f = queue.lastFailure, f != f1 { second = f; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(second != nil,
                "a second identical failure must be a distinct value or onChange observers never see it")
    }
}
