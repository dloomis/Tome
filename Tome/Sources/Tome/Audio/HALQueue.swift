import Foundation
import os

/// Outcome of running a blocking HAL operation with a deadline.
enum HALRunOutcome<T: Sendable>: Sendable {
    case completed(T)
    /// The deadline passed. The operation is STILL RUNNING on the HAL queue —
    /// a HAL call blocked in the kernel cannot be cancelled, so abandoning the
    /// wait is the only option. Its eventual result goes to `onAbandoned`.
    case timedOut
    /// A previously timed-out operation is still stuck on the queue; this one
    /// was refused without enqueueing (it would only stack behind the wedge).
    case wedged
}

/// The one serial home for every blocking CoreAudio/AVAudioEngine call —
/// capture bind/teardown and device enumeration.
///
/// Exists because of the 2026-07-25 beach-ball incidents: `AVAudioEngine.start()`
/// against a Wave Link virtual device wedged inside
/// `HALB_IOThread::StartAndWaitForState` (once with the mixer mid-launch, once
/// with it long-running), and since the bind ran on the main actor the whole
/// app froze — including every recovery mechanism, all main-actor bound. Off
/// the main actor, a wedge costs the audio pipeline, not the app. See
/// docs/superpowers/specs/2026-07-25-main-thread-capture-bind-hang.md.
///
/// Serial and shared by both capture legs deliberately: two `MicCapture`
/// instances binding devices from the same driver concurrently is a new
/// condition device mode would otherwise introduce, and a single lane gives
/// one place to observe "the HAL is wedged" (the latch below). Healthy binds
/// take ~30ms, so serializing the two legs' bring-up costs nothing.
enum HALQueue {
    /// Deadline for every HAL operation. A healthy bind is ~30ms; 5s is two
    /// orders of magnitude above that and still inside a user's patience for
    /// "Start" to respond.
    static let defaultDeadline: Duration = .seconds(5)

    static let queue = DispatchQueue(label: "com.dloomis.tome.hal", qos: .userInitiated)

    /// Count of timed-out operations still stuck on the queue. While nonzero,
    /// new operations are refused up front (`.wedged`) instead of queueing
    /// unbounded behind the block. Decremented when an abandoned operation
    /// finally returns.
    private static let wedgedOps = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
    static var isWedged: Bool { wedgedOps.withLock { $0 > 0 } }

    /// Pure admission/outcome decision, extracted for unit tests: what a run
    /// resolves to given the wedge latch at submit time and whether the work
    /// finished inside the deadline.
    static func decideOutcome(wedgedAtSubmit: Bool, finishedWithinDeadline: Bool) -> HALRunOutcome<Void> {
        if wedgedAtSubmit { return .wedged }
        return finishedWithinDeadline ? .completed(()) : .timedOut
    }

    /// Run `work` on the HAL queue, waiting at most `deadline`.
    ///
    /// On timeout the WAIT is abandoned, never the work — when the driver
    /// finally releases the call, `onAbandoned` runs with its result, on the
    /// HAL queue, immediately after the wedge latch clears (same queue block,
    /// so no other HAL work can interleave between the two).
    static func run<T: Sendable>(
        label: String,
        deadline: Duration = defaultDeadline,
        work: @escaping @Sendable () -> T,
        onAbandoned: (@Sendable (T) -> Void)? = nil
    ) async -> HALRunOutcome<T> {
        guard !isWedged else {
            diagLog("[HAL] \(label) refused — a previous HAL call is still wedged")
            return .wedged
        }
        let resumed = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        let start = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            Task {
                try? await Task.sleep(for: deadline)
                let firstToResume = resumed.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard firstToResume else { return }
                wedgedOps.withLock { $0 += 1 }
                diagLog("[HAL] \(label) exceeded \(deadline) — abandoning the wait; the call keeps running until the driver releases it, and further HAL work fails fast until then")
                continuation.resume(returning: .timedOut)
            }
            queue.async {
                let result = work()
                let firstToResume = resumed.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                if firstToResume {
                    continuation.resume(returning: .completed(result))
                } else {
                    wedgedOps.withLock { $0 -= 1 }
                    diagLog("[HAL] abandoned \(label) returned after \(ContinuousClock.now - start) — wedge cleared")
                    onAbandoned?(result)
                }
            }
        }
    }

    /// Read-only enumeration with the same deadline discipline: a wedged
    /// driver degrades to `fallback` instead of freezing the calling actor.
    /// (A timed-out enumeration still sets the wedge latch — it IS stuck on
    /// the queue — which is exactly right: binds attempted while the HAL
    /// can't even enumerate should fail fast too.)
    static func enumerate<T: Sendable>(
        label: String,
        deadline: Duration = defaultDeadline,
        fallback: T,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        switch await run(label: label, deadline: deadline, work: work) {
        case .completed(let value): return value
        case .timedOut, .wedged: return fallback
        }
    }
}
