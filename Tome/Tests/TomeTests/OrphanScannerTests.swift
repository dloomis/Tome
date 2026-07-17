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
                schema: SessionSidecar.currentSchema, sessionId: "a", sessionGuid: "guid-a",
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

    @Test func micOnlySessionSurfacesAsPrimaryOrphan() throws {
        // A crashed voice memo leaves ONLY <sid>.mic.wav (+sidecar). It must be
        // listed — it is the session's sole audio — with its sidecar paired.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let micWAV = try TestSupport.writeWAV(at: dir.appendingPathComponent("memo.mic.wav"), seconds: 1.5)
        try SessionSidecar.write(
            SessionSidecar(
                schema: SessionSidecar.currentSchema, sessionId: "memo", sessionGuid: "guid-memo",
                transcriptPath: "/vault/Memo.md", startedAt: Date(), sourceApp: "Voice Memo",
                sessionType: .voiceMemo, sampleRate: 48_000, channels: 1,
                bitsPerSample: 32, appVersion: "test"
            ),
            to: SessionSidecar.sidecarURL(forWAV: micWAV)
        )

        let orphans = OrphanScanner.findOrphans(in: dir)
        #expect(orphans.count == 1, "mic-only session must be recoverable, got \(orphans.map(\.wavURL.lastPathComponent))")
        #expect(orphans.first?.wavURL.lastPathComponent == "memo.mic.wav")
        #expect(orphans.first?.sidecar?.sessionType == .voiceMemo)
    }

    @Test func micCompanionStaysHiddenWhenSystemWAVExists() throws {
        // The mic-primary rule must not regress call captures: when <sid>.wav
        // exists, <sid>.mic.wav remains a hidden companion (one listing per session).
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        try TestSupport.writeWAV(at: dir.appendingPathComponent("call.wav"), seconds: 1.5)
        try TestSupport.writeWAV(at: dir.appendingPathComponent("call.mic.wav"), seconds: 1.5)

        let names = OrphanScanner.findOrphans(in: dir).map { $0.wavURL.lastPathComponent }
        #expect(names == ["call.wav"], "got \(names)")
    }

    @Test func micSurfacesWhenSiblingSystemWAVIsAStub() throws {
        // SCStream wedges immediately (44-byte system WAV) while the mic records
        // the whole meeting; app crashes. The mic track is the only real audio —
        // a bare "sibling exists" check would hide it from every recovery path.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let stub = try WAVStreamWriter(url: dir.appendingPathComponent("call.wav"), sampleRate: 48_000)
        stub.close()
        try TestSupport.writeWAV(at: dir.appendingPathComponent("call.mic.wav"), seconds: 1.5)

        let names = OrphanScanner.findOrphans(in: dir).map { $0.wavURL.lastPathComponent }
        #expect(names == ["call.mic.wav"],
                "the only real audio must surface when the system WAV is a stub, got \(names)")
    }

    @Test func rotatedMicSegmentSurfacesWhenNoLiveGenerationHasAudio() throws {
        // Reused memo id → old mic WAV rotated aside → new capture dies before
        // 1s of audio. The rotated segment holds the only real audio and must
        // not be invisible to recovery.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        try TestSupport.writeWAV(at: dir.appendingPathComponent("m.pre-111.mic.wav"), seconds: 1.5)
        let placeholder = try WAVStreamWriter(url: dir.appendingPathComponent("m.mic.wav"), sampleRate: 48_000)
        placeholder.close()

        let names = OrphanScanner.findOrphans(in: dir).map { $0.wavURL.lastPathComponent }
        #expect(names == ["m.pre-111.mic.wav"],
                "a crashed memo's only real audio must not be invisible, got \(names)")
    }

    @Test func discardRemovesWavSidecarAndMicCompanionOnly() throws {
        // Destructive, no-undo path: must remove exactly its session's files.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        let sys = try TestSupport.writeWAV(at: dir.appendingPathComponent("a.wav"), seconds: 1.5)
        try TestSupport.writeWAV(at: dir.appendingPathComponent("a.mic.wav"), seconds: 1.5)
        try SessionSidecar.write(
            SessionSidecar(
                schema: SessionSidecar.currentSchema, sessionId: "a", sessionGuid: "guid-a",
                transcriptPath: "/vault/A.md", startedAt: Date(), sourceApp: "T",
                sessionType: .callCapture, sampleRate: 48_000, channels: 1,
                bitsPerSample: 32, appVersion: "test"
            ),
            to: SessionSidecar.sidecarURL(forWAV: sys)
        )
        try TestSupport.writeWAV(at: dir.appendingPathComponent("bystander.wav"), seconds: 1.5)

        let orphan = try #require(OrphanScanner.findOrphans(in: dir)
            .first { $0.wavURL.lastPathComponent == sys.lastPathComponent })
        OrphanScanner.discard(orphan)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["bystander.wav"], "got \(remaining)")
    }

    @Test func emptyDirectoryYieldsNoOrphans() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        #expect(OrphanScanner.findOrphans(in: dir).isEmpty)
    }
}
