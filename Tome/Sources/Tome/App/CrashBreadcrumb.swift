import Darwin
import Foundation
import os

/// Instrumented-build crash diagnostics. Captures the faulting thread's native
/// backtrace the instant a fatal signal arrives and writes it somewhere durable —
/// so a crash inside an Apple framework (e.g. the macOS 26 SwiftUI/DesignLibrary
/// render path) is diagnosable without depending on the system crash reporter or
/// on `.debug`/`.info` unified-log lines that age out within a day.
///
/// Two outputs, on purpose:
///   1. `~/Library/Application Support/Tome/last-crash.log` — the native backtrace,
///      written from the signal handler via `backtrace_symbols_fd` (async-signal
///      -safe) to a fd opened at install time. Survives even a hard SIGKILL of the
///      reporter.
///   2. os_log at `.fault` under `com.dloomis.tome` — pulled by `log show` alongside
///      the `.notice` breadcrumbs below, giving "last breadcrumb → fault" ordering.
///
/// This is a DIAGNOSTIC build facility. The signal handler does the minimum
/// async-signal-safe work (write a fixed banner + `backtrace_symbols_fd`) then
/// re-raises the default handler (SA_RESETHAND) so the normal .crash report is
/// still produced.
enum CrashBreadcrumb {
    private static let logger = Logger(subsystem: tomeLogSubsystem, category: "crash")

    /// fd for last-crash.log, opened once at install so the handler never allocates.
    nonisolated(unsafe) private static var crashFD: Int32 = -1

    /// Fatal signals worth a backtrace. SIGBUS is the one that killed us on
    /// 2026-07-01 (EXC_BAD_ACCESS in DesignLibrary → ZStack update).
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT]

    /// Install once at launch (idempotent). Opens the crash-log fd and registers
    /// the signal handlers.
    static func install() {
        guard crashFD == -1 else { return }

        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tome", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("last-crash.log").path
            crashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { signalNumber in
            CrashBreadcrumb.handle(signalNumber)
        }
        sigemptyset(&action.sa_mask)
        // Run our handler once, then restore the default so the OS still writes the
        // full .crash report after we've captured the backtrace.
        action.sa_flags = Int32(SA_RESETHAND)
        for sig in fatalSignals {
            sigaction(sig, &action, nil)
        }

        logger.notice("[crash] breadcrumb handler installed (instrumented build)")
    }

    /// Static, allocation-free signal name for the banner (async-signal-safe).
    private static func name(for sig: Int32) -> StaticString {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        default:      return "SIGNAL"
        }
    }

    /// Signal handler. MUST stay async-signal-safe: only fixed C strings + the
    /// `backtrace*` family + `write`. No Swift allocation, no os_log here.
    private static func handle(_ signalNumber: Int32) {
        let banner: StaticString = "\n=== Tome fatal signal: "
        banner.withUTF8Buffer { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
        name(for: signalNumber).withUTF8Buffer { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
        let tail: StaticString = " — backtrace follows ===\n"
        tail.withUTF8Buffer { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = frames.withUnsafeMutableBufferPointer { buf -> Int32 in
            backtrace(buf.baseAddress, Int32(buf.count))
        }
        frames.withUnsafeMutableBufferPointer { buf in
            backtrace_symbols_fd(buf.baseAddress, count, STDERR_FILENO)
            if crashFD >= 0 {
                let hdr: StaticString = "=== Tome fatal signal: "
                hdr.withUTF8Buffer { _ = write(crashFD, $0.baseAddress, $0.count) }
                name(for: signalNumber).withUTF8Buffer { _ = write(crashFD, $0.baseAddress, $0.count) }
                let hdr2: StaticString = " — instrumented backtrace ===\n"
                hdr2.withUTF8Buffer { _ = write(crashFD, $0.baseAddress, $0.count) }
                backtrace_symbols_fd(buf.baseAddress, count, crashFD)
                fsync(crashFD)
            }
        }
        // SA_RESETHAND restored the default disposition; re-raise to get the normal crash.
        raise(signalNumber)
    }

    /// Durable breadcrumb → unified log at `.notice` (persisted, survives the crash,
    /// retrievable via `log show --predicate 'subsystem == "com.dloomis.tome"'`).
    /// Use sparingly around UI lifecycle / state transitions so the last breadcrumb
    /// before a fault localizes the crash.
    static func drop(_ message: String) {
        logger.notice("[crumb] \(message, privacy: .public)")
    }
}
