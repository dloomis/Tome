import Foundation
import Testing
@testable import Tome

/// `FilenameSanitizer.defaultTranscriptStem` — the one derivation of Tome's
/// default note stem, shared by `TranscriptLogger.startSession` (naming) and
/// `TranscriptFinalizer.retypeAsVoiceMemo` (recognizing the call default and
/// producing the voice default). If these ever diverge, the retype stops
/// recognizing Tome's own names — so the logger is pinned to the helper too.
@Suite struct DefaultTranscriptStemTests {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let format = "yyyy-MM-dd HH-mm-ss"

    private var date: String { FilenameSanitizer.formattedDate(start, format: format) }

    private func stem(_ label: String?, fallback: String = "Call Recording") -> String {
        FilenameSanitizer.defaultTranscriptStem(start: start, dateFormat: format, typeLabel: label, fallbackLabel: fallback)
    }

    @Test func nilLabelUsesFallback() {
        #expect(stem(nil) == "\(date) Call Recording")
        #expect(stem(nil, fallback: "Voice Memo") == "\(date) Voice Memo")
    }

    @Test func emptyLabelIsDateOnly() {
        #expect(stem("") == date)
    }

    @Test func customLabelIsAppended() {
        #expect(stem("Quick Notes") == "\(date) Quick Notes")
    }

    @Test func labelThatSanitizesToNothingUsesFallback() {
        // Leading dots are stripped and whitespace trimmed → empty.
        #expect(stem("...") == "\(date) Call Recording")
        #expect(stem("  ", fallback: "Voice Memo") == "\(date) Voice Memo")
    }

    @Test func hostileLabelIsSanitized() {
        #expect(stem("a/b:c") == "\(date) a-b-c")
    }

    @Test(arguments: [
        (SessionType.callCapture, String?.none, "Call Recording"),
        (SessionType.voiceMemo, String?.none, "Voice Memo"),
        (SessionType.callCapture, String?.some(""), "Call Recording"),
        (SessionType.voiceMemo, String?.some("Quick Notes"), "Voice Memo"),
        (SessionType.callCapture, String?.some("..."), "Call Recording"),
        (SessionType.callCapture, String?.some("a/b:c"), "Call Recording"),
    ])
    func loggerNamesNotesWithTheHelper(sessionType: SessionType, label: String?, fallback: String) async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let logger = TranscriptLogger()
        let url = try await logger.startSession(
            sourceApp: "Test",
            vaultPath: dir.path,
            sessionType: sessionType,
            filenameDateFormat: format,
            filenameTypeLabel: label,
            startedAt: start
        )
        _ = await logger.endSession(endTime: start.addingTimeInterval(1))

        #expect(url.deletingPathExtension().lastPathComponent == stem(label, fallback: fallback))
        #expect(url.pathExtension == "md")
    }
}
