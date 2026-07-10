import Foundation

/// Gate for Sparkle update checks. An update check can end in an "Install and
/// Relaunch" prompt — mid-recording, one click would terminate the capture, so
/// checks are refused outright while a session is live. Sparkle retries on its
/// own schedule, so a skipped automatic check costs nothing.
enum UpdatePolicy {
    struct RecordingInProgress: LocalizedError {
        var errorDescription: String? {
            "Update check skipped: a recording is in progress. Tome will check again after the session ends."
        }
    }

    static func mayPerformCheck(isRecording: Bool) throws {
        if isRecording { throw RecordingInProgress() }
    }
}
