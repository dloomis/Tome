import AVFoundation
import Foundation
@testable import Tome

/// Shared fixtures for the destructive-path regression tests. Everything runs
/// against throwaway temp directories — no audio devices, no permissions, no
/// ASR models, no user data.
enum TestSupport {

    /// Fresh unique temp directory. Callers clean up via `defer { remove(url) }`.
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tome-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Mono float32 sine buffer, the same shape the capture taps deliver.
    static func makeBuffer(seconds: Double, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sinf(Float(i) * 0.05) }
        return buf
    }

    /// Write a valid session-shaped WAV via the production writer.
    @discardableResult
    static func writeWAV(at url: URL, seconds: Double) throws -> URL {
        let writer = try WAVStreamWriter(url: url, sampleRate: 48_000)
        try writer.write(makeBuffer(seconds: seconds))
        writer.close()
        return url
    }

    /// Duration a reader would report for the WAV at `url`.
    static func wavDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Create a real vault note through the production logger (so tests operate
    /// on the genuine template, not a hand-rolled imitation) and return the
    /// end-of-session snapshot for finalizer/job tests.
    static func makeSessionNote(
        vault: URL,
        sessionGuid: String = "test-session-guid",
        suggestedFilename: String? = nil,
        utterances: [(speaker: String, text: String, offsetSeconds: Double)] = [("You", "hello world", 2.0)]
    ) async throws -> TranscriptSessionSnapshot {
        let logger = TranscriptLogger()
        let url = try await logger.startSession(
            sourceApp: "Test",
            vaultPath: vault.path,
            sessionGuid: sessionGuid,
            suggestedFilename: suggestedFilename
        )
        _ = url
        let start = Date()
        for u in utterances {
            await logger.append(speaker: u.speaker, text: u.text, timestamp: start.addingTimeInterval(u.offsetSeconds))
        }
        guard let snapshot = await logger.endSession() else {
            throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "endSession returned nil"])
        }
        return snapshot
    }

    /// A snapshot pointing at `filePath` with test-controlled metadata, for cases
    /// that need fields (suggestedFilename, timings) the logger didn't set.
    static func snapshot(
        filePath: URL,
        sessionGuid: String = "test-session-guid",
        start: Date = Date(timeIntervalSinceNow: -60),
        end: Date = Date(),
        speakers: Set<String> = ["You"],
        context: String = "",
        suggestedFilename: String? = nil
    ) -> TranscriptSessionSnapshot {
        TranscriptSessionSnapshot(
            filePath: filePath,
            sessionGuid: sessionGuid,
            calendarEventId: nil,
            sessionStartTime: start,
            sessionEndTime: end,
            speakersDetected: speakers,
            sourceApp: "Test",
            sessionContext: context,
            suggestedFilename: suggestedFilename,
            filenameDateFormat: "yyyy-MM-dd HH-mm-ss"
        )
    }
}
