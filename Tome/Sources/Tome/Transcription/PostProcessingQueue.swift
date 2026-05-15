import Foundation
import Observation

/// Serial background queue for `PostProcessingJob`s. Jobs are fed via an `AsyncStream`
/// and drained by a single long-lived consumer task — so serial-by-construction without
/// any explicit locking. `ProcessInfo.beginActivity` wraps each job run to keep the
/// machine awake and tell macOS this is foreground-priority user work.
@Observable
@MainActor
final class PostProcessingQueue {
    /// Jobs waiting to start (not including `activeJob`).
    private(set) var pendingJobs: [PostProcessingJob] = []

    /// The job currently being processed, if any.
    private(set) var activeJob: PostProcessingJob?

    /// Published completion event; observers use `.onChange(of:)` to react. A new
    /// `JobCompletion` is emitted each time a job finishes successfully — the `jobId`
    /// makes each event unique so downstream observers don't miss duplicate URLs.
    private(set) var lastCompletion: JobCompletion?

    struct JobCompletion: Equatable, Sendable {
        let jobId: String
        let savedURL: URL
        let sourceApp: String
        let sessionType: SessionType
    }

    /// Bindable summary for UI: true while any job is queued or running.
    var isAnyJobRunning: Bool { activeJob != nil || !pendingJobs.isEmpty }

    /// Total jobs still to finish (pending + active). For "Finalizing N transcripts" copy.
    var inFlightCount: Int { pendingJobs.count + (activeJob != nil ? 1 : 0) }

    private let asr: ASRCoordinator
    private let jobStream: AsyncStream<PostProcessingJob>
    private let jobContinuation: AsyncStream<PostProcessingJob>.Continuation

    init(asr: ASRCoordinator) {
        (jobStream, jobContinuation) = AsyncStream.makeStream()
        self.asr = asr
        // Strong-self: the queue is an app-lifetime singleton on AppServices, so the
        // retain cycle is bounded by app shutdown. A weak self made the consumer
        // exit silently if any observer dropped its reference — losing jobs.
        Task {
            await self.consume()
        }
    }

    /// Add a job. The consumer will pick it up in FIFO order.
    func enqueue(_ job: PostProcessingJob) {
        pendingJobs.append(job)
        jobContinuation.yield(job)
    }

    /// Close the queue's ingest stream. Any in-flight job finishes; no new work is accepted.
    /// Called during app termination.
    func shutdown() {
        jobContinuation.finish()
    }

    private func consume() async {
        for await job in jobStream {
            // Move job from pending → active
            pendingJobs.removeAll { $0.id == job.id }
            activeJob = job

            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Finalizing \(job.handle.transcript.filePath.lastPathComponent)"
            )

            do {
                let savedURL = try await job.run(using: asr)
                lastCompletion = JobCompletion(
                    jobId: job.id,
                    savedURL: savedURL,
                    sourceApp: job.handle.sourceApp,
                    sessionType: job.handle.sessionType
                )
            } catch {
                diagLog("[QUEUE] Job \(job.id) failed: \(error)")
            }

            ProcessInfo.processInfo.endActivity(activity)
            activeJob = nil
        }
    }
}
