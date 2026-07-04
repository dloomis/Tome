#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises.
/// Returns nil on success, or "<name>: <reason>" if an exception was thrown.
///
/// AVFoundation raises NSExceptions from misconfiguration (e.g.
/// -[AVAudioNode installTapOnBus:...] on a hardware format mismatch). An
/// NSException unwinding through Swift async frames is undefined behavior —
/// it corrupts the concurrency runtime's state and the process crashes later
/// in an unrelated stack (see the 2026-07-03 EXC_BAD_ACCESS in
/// swift_task_isCurrentExecutor). Wrap any AVAudioEngine call that can raise
/// in this guard and surface the string as a capture error instead.
FOUNDATION_EXPORT NSString *_Nullable TomeCatchObjCException(void(NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
