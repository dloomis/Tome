import Foundation
import Testing
@testable import Tome

@Suite struct SessionSidecarTests {

    private func makeSidecar(transcriptPath: String = "/vault/Note.md") -> SessionSidecar {
        SessionSidecar(
            schema: SessionSidecar.currentSchema,
            sessionId: "session_2026-07-05_10-00-00",
            transcriptPath: transcriptPath,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            sourceApp: "Teams",
            sessionType: .callCapture,
            sampleRate: 48_000,
            channels: 1,
            bitsPerSample: 32,
            appVersion: "1.4.0"
        )
    }

    @Test func emitWritesSidecarNextToWAV() throws {
        // Shared emission helper — used by SystemAudioCapture for call captures
        // and by the engine for mic-only sessions (which previously never got a
        // sidecar and were invisible to crash recovery).
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let wav = dir.appendingPathComponent("memo.mic.wav")
        let context = SessionRecordingContext(
            sessionId: "memo",
            transcriptURL: URL(fileURLWithPath: "/vault/Memo.md"),
            sourceApp: "Voice Memo",
            sessionType: .voiceMemo,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        SessionSidecar.emit(forWAV: wav, context: context, sampleRate: 48_000)

        let read = try SessionSidecar.read(from: SessionSidecar.sidecarURL(forWAV: wav))
        #expect(read.sessionId == "memo")
        #expect(read.sessionType == .voiceMemo)
        #expect(read.transcriptPath == "/vault/Memo.md")
        #expect(read.startedAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(read.schema == SessionSidecar.currentSchema)
    }

    @Test func roundTrip() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let wav = dir.appendingPathComponent("s.wav")
        let url = SessionSidecar.sidecarURL(forWAV: wav)
        try SessionSidecar.write(makeSidecar(), to: url)
        let read = try SessionSidecar.read(from: url)
        #expect(read.sessionId == "session_2026-07-05_10-00-00")
        #expect(read.transcriptPath == "/vault/Note.md")
        #expect(SessionSidecar.wavURL(forSidecar: url) == wav)
    }

    @Test func updateTranscriptPathRewritesOnlyThePath() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let wav = dir.appendingPathComponent("s.wav")
        try SessionSidecar.write(makeSidecar(), to: SessionSidecar.sidecarURL(forWAV: wav))

        SessionSidecar.updateTranscriptPath(forWAV: wav, to: URL(fileURLWithPath: "/vault/Renamed Meeting.md"))

        let read = try SessionSidecar.read(from: SessionSidecar.sidecarURL(forWAV: wav))
        #expect(read.transcriptPath == "/vault/Renamed Meeting.md")
        // Every other field preserved.
        #expect(read.sessionId == "session_2026-07-05_10-00-00")
        #expect(read.sourceApp == "Teams")
        #expect(read.sessionType == .callCapture)
        #expect(read.startedAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(read.appVersion == "1.4.0")
    }

    @Test func updateTranscriptPathIsNoOpWithoutSidecar() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let wav = dir.appendingPathComponent("nosidecar.wav")
        SessionSidecar.updateTranscriptPath(forWAV: wav, to: URL(fileURLWithPath: "/x.md"))
        #expect(!FileManager.default.fileExists(atPath: SessionSidecar.sidecarURL(forWAV: wav).path),
                "must not conjure a sidecar out of nothing")
    }

    @Test func incompatibleSidecarFailsDecodeRatherThanMispairing() throws {
        // Upgrade contract: a sidecar this build can't decode must degrade to
        // "no sidecar" (manual recovery), never to a wrong pairing.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("old.session.json")
        try #"{"schema": 0, "sessionId": "s"}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try SessionSidecar.read(from: url) }
    }
}
