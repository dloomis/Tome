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
        /// Occurrence stamp — same rationale as `JobFailure.failedAt`: a reused
        /// session id finishing at the same path must still read as a new event.
        let completedAt: Date
    }

    /// Published when a job throws. Observers (ContentView) surface it to the
    /// user and walk the API lifecycle out of `.transcribing` — a failure that
    /// only reaches `diagLog` looks exactly like success to everyone else.
    private(set) var lastFailure: JobFailure?

    struct JobFailure: Equatable, Sendable {
        let jobId: String
        let message: String
        let sessionType: SessionType
        /// Occurrence stamp. Session ids are second-granular and reusable by API
        /// callers, so two consecutive identical failures would otherwise compare
        /// equal — and `.onChange` observers would never see the second one.
        let failedAt: Date
    }

    /// Published when a job discards a short session (see `AppSettings.discardShortMeetings`).
    /// Distinct from completion: nothing was written, so observers must not show a
    /// "Saved" banner or an open-file action — the transcript is gone by design.
    private(set) var lastDiscard: JobDiscard?

    struct JobDiscard: Equatable, Sendable {
        let jobId: String
        let durationSeconds: Int
        /// Occurrence stamp — same rationale as `JobFailure.failedAt`: a reused
        /// session id discarded twice must still read as a new event.
        let discardedAt: Date
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
                switch try await job.run(using: asr) {
                case .saved(let savedURL):
                    lastCompletion = JobCompletion(
                        jobId: job.id,
                        savedURL: savedURL,
                        sourceApp: job.handle.sourceApp,
                        sessionType: job.handle.sessionType,
                        completedAt: Date()
                    )
                case .discarded(_, let durationSeconds):
                    diagLog("[QUEUE] Job \(job.id) discarded (short session, \(durationSeconds)s)")
                    lastDiscard = JobDiscard(
                        jobId: job.id,
                        durationSeconds: durationSeconds,
                        discardedAt: Date()
                    )
                }
            } catch {
                diagLog("[QUEUE] Job \(job.id) failed: \(error)")
                lastFailure = JobFailure(
                    jobId: job.id,
                    message: failureMessage(for: error),
                    sessionType: job.handle.sessionType,
                    failedAt: Date()
                )
            }

            ProcessInfo.processInfo.endActivity(activity)
            activeJob = nil
        }
    }

    private func failureMessage(for error: PostProcessingError) -> String {
        switch error {
        case .diarizeFailed(let m): return "Diarization failed: \(m)"
        case .reTranscribeFailed(let m): return "Re-transcription failed: \(m)"
        case .markdownReadFailed(let m): return "Couldn't read the transcript: \(m)"
        case .markdownWriteFailed(let m): return "Couldn't write the transcript: \(m)"
        case .cancelled: return "Finalization was cancelled"
        }
    }
}
