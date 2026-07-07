import Foundation
import Testing
@testable import Tome

/// The scanner's filtering contract, including the new rotated `.pre-` names:
/// system audio (fresh or rotated) surfaces for recovery; mic companions and
/// header-only placeholders never do.
@Suite struct OrphanScannerTests {

    @Test func listsSystemWAVsIncludingRotatedAndSkipsMicCompanions() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // A crashed session: system WAV + sidecar + mic companion + rotated mic segment.
        let sysWAV = try TestSupport.writeWAV(at: dir.appendingPathComponent("a.wav"), seconds: 1.5)
        try SessionSidecar.write(
            SessionSidecar(
                schema: SessionSidecar.currentSchema, sessionId: "a",
                transcriptPath: "/vault/A.md", startedAt: Date(), sourceApp: "Test",
                sessionType: .callCapture, sampleRate: 48_000, channels: 1,
                bitsPerSample: 32, appVersion: "test"
            ),
            to: SessionSidecar.sidecarURL(forWAV: sysWAV)
        )
        try TestSupport.writeWAV(at: dir.appendingPathComponent("a.mic.wav"), seconds: 1.5)
        try TestSupport.writeWAV(at: dir.appendingPathComponent("a.pre-123.mic.wav"), seconds: 1.5)

        // A rotated *system* segment from a duplicate-id collision — real audio,
        // must surface (with no sidecar → manual recovery path).
        try TestSupport.writeWAV(at: dir.appendingPathComponent("b.pre-456.wav"), seconds: 1.2)

        // Header-only placeholder (a start that never received audio) — skipped.
        let placeholder = try WAVStreamWriter(url: dir.appendingPathComponent("c.wav"), sampleRate: 48_000)
        placeholder.close()

        let orphans = OrphanScanner.findOrphans(in: dir)
        let names = Set(orphans.map { $0.wavURL.lastPathComponent })

        #expect(names == ["a.wav", "b.pre-456.wav"], "got \(names)")
        let a = try #require(orphans.first { $0.wavURL.lastPathComponent == "a.wav" })
        #expect(a.sidecar?.transcriptPath == "/vault/A.md", "sidecar pairing must survive the scan")
        let b = try #require(orphans.first { $0.wavURL.lastPathComponent == "b.pre-456.wav" })
        #expect(b.sidecar == nil)
    }

    @Test func emptyDirectoryYieldsNoOrphans() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        #expect(OrphanScanner.findOrphans(in: dir).isEmpty)
    }
}
