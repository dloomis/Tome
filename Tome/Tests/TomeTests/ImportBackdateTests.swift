@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Tome

/// Scripted VAD for the transcriber half of this suite — emits speech-boundary
/// events by chunk index, so no silero model is needed.
private struct BackdateScriptedVAD: VADStream {
    let events: [Int: VADEvent]
    var chunkIndex = 0

    mutating func process(_ chunk: [Float]) async throws -> VADEvent? {
        defer { chunkIndex += 1 }
        return events[chunkIndex]
    }
}

/// Thread-safe collector that keeps each finalized utterance's start *time*
/// (onFinal fires off-main).
private final class TimedUtteranceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(text: String, start: Date)] = []
    func append(_ text: String, _ start: Date) { lock.withLock { _entries.append((text, start)) } }
    var entries: [(text: String, start: Date)] { lock.withLock { _entries } }
}

/// An imported recording is a session that *already happened*: the note must be
/// dated by the recording, not by the import. These pin the backdating
/// parameters on the live-recording types — and, just as importantly, pin that
/// omitting them leaves every existing caller behaving exactly as before.
@Suite struct ImportBackdateTests {

    /// Production formats dates with a plain local-timezone `DateFormatter`
    /// (`FilenameSanitizer.formattedDate`, `TranscriptLogger.documentHeader`), so
    /// expectations are built the same way rather than hard-coded.
    private static func localString(_ date: Date, _ format: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = format
        return fmt.string(from: date)
    }

    /// 90 days back: far enough that no field can match "today" by accident.
    private static let recordedAt = Date(timeIntervalSinceNow: -90 * 86_400)

    // MARK: - startSession(startedAt:)

    @Test func backdatedStartSessionDatesFilenameAndFrontmatter() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let recordedAt = Self.recordedAt
        let logger = TranscriptLogger()
        let url = try await logger.startSession(
            sourceApp: "Imported",
            vaultPath: vault.path,
            sessionType: .voiceMemo,
            sessionGuid: "import-guid",
            startedAt: recordedAt
        )

        #expect(url.lastPathComponent == "\(Self.localString(recordedAt, "yyyy-MM-dd HH-mm-ss")) Voice Memo.md")

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("created: \"\(Self.localString(recordedAt, "yyyy-MM-dd"))\""))
        #expect(content.contains("time: \"\(Self.localString(recordedAt, "HH:mm"))\""))
        #expect(!content.contains("created: \"\(Self.localString(Date(), "yyyy-MM-dd"))\""),
                "a backdated session must not carry the import date")
        #expect(content.contains("# Voice Memo — \(Self.localString(recordedAt, "yyyy-MM-dd HH:mm"))"),
                "the body heading is derived from the same anchor")

        let snapshot = try #require(await logger.endSession())
        #expect(snapshot.sessionStartTime == recordedAt)
    }

    // MARK: - endSession(endTime:)

    @Test func backdatedEndSessionPinsTheRecordingWindowAndDuration() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let recordedAt = Self.recordedAt
        let audioDuration: TimeInterval = 754.5  // 12:34

        let logger = TranscriptLogger()
        _ = try await logger.startSession(
            sourceApp: "Imported",
            vaultPath: vault.path,
            sessionType: .voiceMemo,
            startedAt: recordedAt
        )
        await logger.append(speaker: "You", text: "imported words", timestamp: recordedAt.addingTimeInterval(3))
        let snapshot = try #require(await logger.endSession(endTime: recordedAt.addingTimeInterval(audioDuration)))

        #expect(snapshot.sessionStartTime == recordedAt)
        #expect(snapshot.sessionEndTime == recordedAt.addingTimeInterval(audioDuration))
        #expect(snapshot.sessionEndTime.timeIntervalSince(snapshot.sessionStartTime) == audioDuration,
                "duration must be the audio length, not the wall-clock time the import took")

        // The window is only useful if it survives into the finalized note.
        let finalPath = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snapshot)
        let content = try String(contentsOf: finalPath, encoding: .utf8)
        #expect(content.contains("duration: \"12:34\""))
        #expect(content.contains("**Duration:** 12:34"))
    }

    // MARK: - Offsets against the backdated start

    @Test func utteranceOffsetsAreMeasuredFromTheBackdatedStart() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let recordedAt = Self.recordedAt
        let logger = TranscriptLogger()
        let url = try await logger.startSession(
            sourceApp: "Imported",
            vaultPath: vault.path,
            sessionType: .voiceMemo,
            startedAt: recordedAt
        )
        await logger.append(speaker: "You", text: "first", timestamp: recordedAt.addingTimeInterval(12.5))
        await logger.append(speaker: "You", text: "second", timestamp: recordedAt.addingTimeInterval(90))
        _ = await logger.endSession(endTime: recordedAt.addingTimeInterval(120))

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("**You** (12.500)\nfirst"))
        #expect(content.contains("**You** (90.000)\nsecond"))
        // The pre-fix bug this guards: anchoring at Date() would clamp every
        // offset of a backdated session to 0 (formatTimeOffset floors at 0).
        #expect(!content.contains("(0.000)"))
    }

    @Test func offsetsSurviveTheSelfHealRebuildOfABackdatedSession() async throws {
        // The self-heal rebuilds the whole body from `sessionStartTime`; a
        // backdated anchor has to be the one it replays against.
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let recordedAt = Self.recordedAt
        let logger = TranscriptLogger()
        let url = try await logger.startSession(
            sourceApp: "Imported",
            vaultPath: vault.path,
            sessionType: .voiceMemo,
            startedAt: recordedAt
        )
        await logger.append(speaker: "You", text: "before deletion", timestamp: recordedAt.addingTimeInterval(4))
        try FileManager.default.removeItem(at: url)
        await logger.append(speaker: "You", text: "after deletion", timestamp: recordedAt.addingTimeInterval(8))

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("created: \"\(Self.localString(recordedAt, "yyyy-MM-dd"))\""))
        #expect(content.contains("**You** (4.000)\nbefore deletion"))
        #expect(content.contains("**You** (8.000)\nafter deletion"))
        _ = await logger.endSession(endTime: recordedAt.addingTimeInterval(10))
    }

    // MARK: - Behavior identity for existing (live-path) callers

    @Test func defaultedLoggerParametersStillAnchorAtNow() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let beforeStart = Date()
        let url = try await logger.startSession(sourceApp: "T", vaultPath: vault.path)
        let afterStart = Date()
        await logger.append(speaker: "You", text: "live words", timestamp: Date())
        let beforeEnd = Date()
        let snapshot = try #require(await logger.endSession())
        let afterEnd = Date()

        #expect(snapshot.sessionStartTime >= beforeStart && snapshot.sessionStartTime <= afterStart,
                "an omitted startedAt must still stamp the moment startSession ran")
        #expect(snapshot.sessionEndTime >= beforeEnd && snapshot.sessionEndTime <= afterEnd,
                "an omitted endTime must still stamp the stop moment, not finalize time")
        #expect(url.lastPathComponent.hasPrefix(Self.localString(snapshot.sessionStartTime, "yyyy-MM-dd")))
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("created: \"\(Self.localString(snapshot.sessionStartTime, "yyyy-MM-dd"))\""))
        #expect(content.contains("# Call Recording — "), "default sessionType is unchanged")
    }

    // MARK: - StreamingTranscriber(baseTime:)

    private func makeChunkBuffer() -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let frames = 4096
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = 0.5 * sinf(Float(i) * 0.1) }
        return buf
    }

    /// Nine 4096-sample chunks with speech starting at chunk 4. Pre-roll (2
    /// chunks) pulls the segment start back to sample 8192 = 0.512s of audio.
    private func runNineChunks(baseTime: Date?, collector: TimedUtteranceCollector) async {
        let coordinator = ASRCoordinator()
        await coordinator.install(backend: FakeBackend(model: .parakeetTDTv3), token: 1)
        let transcriber = StreamingTranscriber(
            asrCoordinator: coordinator,
            vad: BackdateScriptedVAD(events: [4: .speechStart]),
            speaker: .you,
            audioSource: .microphone,
            baseTime: baseTime,
            onPartial: { _ in },
            onFinal: { text, start in collector.append(text, start) }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        for _ in 0..<9 { continuation.yield(makeChunkBuffer()) }
        continuation.finish()
        _ = await transcriber.run(stream: stream)
    }

    @Test func injectedBaseTimeAnchorsUtteranceTimestampsAtTheRecordingStart() async throws {
        let recordedAt = Self.recordedAt
        let collector = TimedUtteranceCollector()
        await runNineChunks(baseTime: recordedAt, collector: collector)

        let entries = collector.entries
        #expect(entries.count == 1)
        let start = try #require(entries.first?.start)
        // 8192 samples of pre-rolled lead-in at 16kHz. Tolerance, not equality:
        // Date arithmetic 90 days out has ~1e-7s of representable resolution.
        #expect(abs(start.timeIntervalSince(recordedAt) - 8192.0 / 16_000.0) < 1e-4)
    }

    @Test func omittedBaseTimeStillAnchorsAtFirstBufferArrival() async throws {
        let collector = TimedUtteranceCollector()
        let before = Date()
        await runNineChunks(baseTime: nil, collector: collector)
        let after = Date()

        let start = try #require(collector.entries.first?.start)
        let audioOffset = 8192.0 / 16_000.0
        #expect(start >= before.addingTimeInterval(audioOffset),
                "the live path must still capture Date() when the first buffer arrives")
        #expect(start <= after.addingTimeInterval(audioOffset))
    }
}
