import AppKit
import Foundation

/// AppKit / distributed-notification departure signals for the
/// forgotten-recording failsafe (spec
/// `docs/superpowers/specs/2026-10-06-forgotten-recording-failsafe.md` §2, §5).
///
/// Started and stopped with the session; funnels into the same sink as the
/// engine's `onDepartureSignal`. Emits signals unconditionally — whether they
/// matter is `AutoStopPolicy`'s call. No HAL / CoreAudio here.
///
/// - `displayRemoved`: `didChangeScreenParametersNotification` with fewer
///   screens than last seen.
/// - `screenLocked`: distributed `com.apple.screenIsLocked`.
/// - `willSleep` → `onWillSleep` only. It never stops anything: the sleep
///   duration is unknowable at that point (R1 is decided at wake by the
///   session tick's clock gap).
@MainActor
final class DepartureMonitor {
    var onSignal: ((DepartureSignal) -> Void)?
    var onWillSleep: (() -> Void)?

    private var screenObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var lastScreenCount = 0

    private nonisolated static let screenLockedName = Notification.Name("com.apple.screenIsLocked")

    var isRunning: Bool { screenObserver != nil }

    /// Idempotent. Remembers the current screen count as the baseline.
    func start() {
        guard screenObserver == nil else { return }
        lastScreenCount = NSScreen.screens.count

        // Every observer is registered on `queue: .main`, so each closure runs
        // on the main thread and enters the main actor synchronously via
        // `assumeIsolated` (traps if that ever stops being true). Synchronous
        // matters for willSleep: the handler runs before the system proceeds.
        // Closures capture only `weak self`; no Notification object is used.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }

        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.screenLockedName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.screenLocked) }
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
    }

    /// Idempotent. Removes every observer.
    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        screenObserver = nil
        lockObserver = nil
        sleepObserver = nil
    }

    /// Pure: did the screen count drop? (A count that rises or holds — a
    /// display attached, a resolution change — is not a departure.)
    nonisolated static func displayWasRemoved(previousCount: Int, currentCount: Int) -> Bool {
        currentCount < previousCount
    }

    // MARK: - Private

    private func screenParametersChanged() {
        guard screenObserver != nil else { return }
        let current = NSScreen.screens.count
        let removed = Self.displayWasRemoved(previousCount: lastScreenCount, currentCount: current)
        lastScreenCount = current
        if removed { emit(.displayRemoved) }
    }

    private func willSleep() {
        guard screenObserver != nil else { return }
        onWillSleep?()
    }

    private func emit(_ signal: DepartureSignal) {
        guard screenObserver != nil else { return }
        diagLog("[AUTOSTOP] signal=\(signal.rawValue)")
        onSignal?(signal)
    }
}
