import AVFoundation
import Foundation
import Testing
@testable import Tome

/// The writer's two contracts: a crash mid-write leaves a readable WAV, and
/// claiming a path never destroys audio already there (rotate, don't truncate).
@Suite struct WAVStreamWriterTests {

    @Test func rotatesExistingSystemWAVInsteadOfTruncating() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("session_A.wav")
        try TestSupport.writeWAV(at: url, seconds: 2)
        let originalData = try Data(contentsOf: url)

        // Second writer claims the same path (reused session id).
        try TestSupport.writeWAV(at: url, seconds: 1)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let rotated = names.filter { $0.hasPrefix("session_A.pre-") && $0.hasSuffix(".wav") }
        #expect(rotated.count == 1, "old audio must be set aside exactly once, got \(names)")

        let rotatedURL = dir.appendingPathComponent(try #require(rotated.first))
        #expect(try Data(contentsOf: rotatedURL) == originalData, "rotated segment must be byte-identical")
        #expect(abs(try TestSupport.wavDuration(rotatedURL) - 2.0) < 0.01)
        #expect(abs(try TestSupport.wavDuration(url) - 1.0) < 0.01)
    }

    @Test func micRotationKeepsMicWavTail() throws {
        // The orphan scanner classifies companions by the `.mic.wav` suffix; a
        // rotated mic segment must keep that tail or it would surface as a
        // diarization primary.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("session_A.mic.wav")
        try TestSupport.writeWAV(at: url, seconds: 1)
        try TestSupport.writeWAV(at: url, seconds: 1)

        let rotated = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("session_A.pre-") }
        #expect(rotated.count == 1)
        #expect(try #require(rotated.first).hasSuffix(".mic.wav"))
    }

    @Test func fileIsReadableWithoutClose() throws {
        // Crash-safety contract: header sizes are refreshed on every write, so a
        // process that dies without close() still leaves a parseable WAV with all
        // written frames accounted for.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("crash.wav")
        let writer = try WAVStreamWriter(url: url, sampleRate: 48_000)
        try writer.write(TestSupport.makeBuffer(seconds: 1.5))
        try writer.write(TestSupport.makeBuffer(seconds: 0.5))
        // Deliberately no close() — simulates SIGKILL/crash. (The handle leaks
        // for the duration of the test process; that's the point.)

        #expect(abs(try TestSupport.wavDuration(url) - 2.0) < 0.01,
                "un-closed WAV must read back with every written frame")
    }

    @Test func appendModeContinuesExistingFileWithoutRotation() throws {
        // Upstream's mid-session mic-swap fix: `.append` reopens the same WAV and
        // resumes the running dataBytes count, so pre-swap audio stays in the file
        // and header sizes remain accurate across the reopen.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let url = dir.appendingPathComponent("session_A.mic.wav")
        try TestSupport.writeWAV(at: url, seconds: 1)

        let appender = try WAVStreamWriter(url: url, sampleRate: 48_000, mode: .append)
        try appender.write(TestSupport.makeBuffer(seconds: 1))
        appender.close()

        #expect(abs(try TestSupport.wavDuration(url) - 2.0) < 0.01,
                "appended audio must accumulate after the original second")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["session_A.mic.wav"], "append must not rotate, got \(names)")
    }

    @Test func freshPathNeedsNoRotation() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        try TestSupport.writeWAV(at: dir.appendingPathComponent("fresh.wav"), seconds: 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["fresh.wav"], "no stray rotation artifacts on first use, got \(names)")
    }
}
