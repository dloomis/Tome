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

/// Outcome of a read-only HAL query. The distinction is load-bearing: a query
/// the HAL never answered is NOT the same fact as "there is no such device",
/// and collapsing the two made a wedged driver look like a vanished
/// microphone (2026-07-27 — a refused UID lookup sent `start()` down the
/// "selected mic unavailable, recording from the system default" path, whose
/// default was the very device that had just wedged).
enum HALQueryResult<T: Sendable>: Sendable {
    case answered(T)
    /// The HAL is unresponsive (this call timed out, or a previous one is
    /// still stuck on the same lane). No information about the devices.
    case unavailable

    /// The answer, or `fallback` when the HAL never responded. For callers
    /// where a degraded answer is harmless (names for log lines, banners).
    func value(or fallback: T) -> T {
        if case .answered(let value) = self { return value }
        return fallback
    }
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
/// Binds are serial and shared by both capture legs deliberately: two
/// `MicCapture` instances binding devices from the same driver concurrently is
/// a new condition device mode would otherwise introduce. Healthy binds take
/// ~30ms, so serializing the two legs' bring-up costs nothing.
///
/// Read-only queries (enumeration, UID↔id, default device) run on a SEPARATE
/// lane with its own wedge latch. They used to share the bind lane, which made
/// one wedged `AVAudioEngine.start()` disable device enumeration process-wide:
/// the queries queued behind the stuck bind, timed out in turn, and raised the
/// latch again — so the Settings pickers went stale exactly when the user
/// needed them to switch away from the offending device (2026-07-27). The
/// lanes are independent because the failure modes are: a bind opens an IO
/// stream and can block in `HALB_IOThread::StartAndWaitForState`, while a
/// property read on the system object does not. A query that blocks anyway
/// wedges only queries, and binds stay admissible.
enum HALQueue {
    /// Deadline for every HAL operation. A healthy bind is ~30ms; 5s is two
    /// orders of magnitude above that and still inside a user's patience for
    /// "Start" to respond.
    static let defaultDeadline: Duration = .seconds(5)

    /// Which serial lane an operation runs on. Each lane has its own queue and
    /// its own wedge latch — a wedge on one must not disable the other.
    enum Lane: Sendable {
        /// Capture bind/teardown: `AVAudioEngine.start()` and friends.
        case bind
        /// Read-only CoreAudio property reads.
        case query
    }

    static let queue = DispatchQueue(label: "com.dloomis.tome.hal", qos: .userInitiated)
    private static let queryQueue = DispatchQueue(label: "com.dloomis.tome.hal-query", qos: .userInitiated)

    private static func dispatchQueue(for lane: Lane) -> DispatchQueue {
        switch lane {
        case .bind: return queue
        case .query: return queryQueue
        }
    }

    /// Count of timed-out operations still stuck on each lane. While nonzero,
    /// new operations on THAT lane are refused up front (`.wedged`) instead of
    /// queueing unbounded behind the block. Decremented when an abandoned
    /// operation finally returns.
    private static let bindWedgedOps = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
    private static let queryWedgedOps = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    private static func wedgedOps(for lane: Lane) -> OSAllocatedUnfairLock<Int> {
        switch lane {
        case .bind: return bindWedgedOps
        case .query: return queryWedgedOps
        }
    }

    static func isWedged(_ lane: Lane) -> Bool { wedgedOps(for: lane).withLock { $0 > 0 } }

    /// True when EITHER lane is wedged. Callers deciding whether their own
    /// operation can proceed should ask about their lane instead.
    static var isWedged: Bool { isWedged(.bind) || isWedged(.query) }

    /// Posted (from the HAL queue) when the last wedged operation finally
    /// returns and the latch clears. Consumers that degraded while wedged —
    /// the Settings device list enumerating to empty — recover on this signal;
    /// nothing else re-triggers them, because the wedge clearing is not a
    /// device-set change and CoreAudio listeners never fire for it
    /// (2026-07-26 stale "(unavailable)" pickers).
    static let wedgeClearedNotification = Notification.Name("com.dloomis.tome.hal-wedge-cleared")

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
        lane: Lane = .bind,
        deadline: Duration = defaultDeadline,
        work: @escaping @Sendable () -> T,
        onAbandoned: (@Sendable (T) -> Void)? = nil
    ) async -> HALRunOutcome<T> {
        let wedgedOps = wedgedOps(for: lane)
        let queue = dispatchQueue(for: lane)
        guard !isWedged(lane) else {
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
                    let latchCleared = wedgedOps.withLock { count -> Bool in
                        count -= 1
                        return count == 0
                    }
                    diagLog("[HAL] abandoned \(label) returned after \(ContinuousClock.now - start) — wedge cleared")
                    onAbandoned?(result)
                    if latchCleared {
                        NotificationCenter.default.post(name: wedgeClearedNotification, object: nil)
                    }
                }
            }
        }
    }

    /// Read-only query with the same deadline discipline, on the query lane: a
    /// wedged driver reports `.unavailable` instead of freezing the calling
    /// actor. A timed-out query still sets the QUERY latch (it is stuck on that
    /// lane) — binds remain admissible, because a driver that can't answer a
    /// property read may still bind, and the user's escape route from a wedge
    /// is to bind a different device.
    static func query<T: Sendable>(
        label: String,
        deadline: Duration = defaultDeadline,
        _ work: @escaping @Sendable () -> T
    ) async -> HALQueryResult<T> {
        switch await run(label: label, lane: .query, deadline: deadline, work: work) {
        case .completed(let value): return .answered(value)
        case .timedOut, .wedged: return .unavailable
        }
    }

    /// `query` for callers that treat "no answer" and `fallback` alike.
    /// Anything deciding whether a device EXISTS must use `query` instead.
    static func enumerate<T: Sendable>(
        label: String,
        deadline: Duration = defaultDeadline,
        fallback: T,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await query(label: label, deadline: deadline, work).value(or: fallback)
    }
}
