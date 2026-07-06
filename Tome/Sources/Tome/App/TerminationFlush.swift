import Foundation

/// Quit-time emergency flush. `applicationShouldTerminate` needs to drain the
/// live session's writer state before exit, and it must BLOCK the main thread
/// until that lands (returning `.terminateNow` ends the process) — so the flush
/// itself has to run somewhere the blocked main thread can't starve.
///
/// The previous implementation used `Task {}` inside the MainActor delegate;
/// the task inherited main-actor isolation and could never start while the main
/// thread sat in `sema.wait`, so every quit burned the full timeout and the
/// flush never actually ran. `Task.detached` breaks that inheritance; the actor
/// hops inside (`logger`/`store` are actors) run on the cooperative pool.
enum TerminationFlush {
    /// Returns true if the flush completed within `timeout`. Safe (and intended)
    /// to call from the main thread.
    @discardableResult
    static func run(logger: TranscriptLogger, store: SessionStore, timeout: TimeInterval) -> Bool {
        let sema = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = await logger.endSession()
            await store.endSession()
            sema.signal()
        }
        return sema.wait(timeout: .now() + timeout) == .success
    }
}
