import AVFoundation
import Foundation
import Testing
@testable import Tome

/// The import stage's pure rules: timestamp derivation (§4) and the validation
/// gates (§5). No audio devices, no models — fixtures are written to temp dirs
/// through the production WAV writer.
@Suite struct ImportSupportTests {

    // MARK: - Timestamp derivation (§4)

    private struct TimestampCase {
        let label: String
        let creation: Date?
        let modification: Date?
        let expectedStart: Date
        let expectedAnchor: ImportSupport.TimestampAnchor
    }

    @Test func timestampDerivationTable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 120
        let recordedAt = now.addingTimeInterval(-86_400)

        let cases: [TimestampCase] = [
            .init(label: "creation date wins",
                  creation: recordedAt,
                  modification: now.addingTimeInterval(-10),
                  expectedStart: recordedAt,
                  expectedAnchor: .creationDate),
            .init(label: "missing creation falls back to modification − duration",
                  creation: nil,
                  modification: recordedAt.addingTimeInterval(duration),
                  expectedStart: recordedAt,
                  expectedAnchor: .modificationDate),
            .init(label: "epoch-zero creation is not a real stamp",
                  creation: Date(timeIntervalSince1970: 0),
                  modification: recordedAt.addingTimeInterval(duration),
                  expectedStart: recordedAt,
                  expectedAnchor: .modificationDate),
            .init(label: "future-dated creation is refused",
                  creation: now.addingTimeInterval(3_600),
                  modification: recordedAt.addingTimeInterval(duration),
                  expectedStart: recordedAt,
                  expectedAnchor: .modificationDate),
            .init(label: "both unusable falls back to now − duration",
                  creation: nil,
                  modification: nil,
                  expectedStart: now.addingTimeInterval(-duration),
                  expectedAnchor: .importTime),
            .init(label: "future modification is refused too",
                  creation: Date(timeIntervalSince1970: 0),
                  modification: now.addingTimeInterval(60),
                  expectedStart: now.addingTimeInterval(-duration),
                  expectedAnchor: .importTime),
        ]

        for c in cases {
            let derived = ImportSupport.deriveTimestamps(
                creationDate: c.creation,
                modificationDate: c.modification,
                duration: duration,
                now: now
            )
            #expect(derived.anchor == c.expectedAnchor, "\(c.label): anchor")
            #expect(abs(derived.start.timeIntervalSince(c.expectedStart)) < 0.001, "\(c.label): start")
            #expect(abs(derived.end.timeIntervalSince(derived.start) - duration) < 0.001,
                    "\(c.label): end is always start + duration")
        }
    }

    /// A stamp exactly at `now` is a legitimate just-finished recording, not skew.
    @Test func creationDateAtNowIsAccepted() {
        let now = Date()
        let derived = ImportSupport.deriveTimestamps(
            creationDate: now, modificationDate: nil, duration: 5, now: now
        )
        #expect(derived.anchor == .creationDate)
        #expect(derived.start == now)
    }

    @Test func fileDatesReadBackWhatWasWritten() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let url = try TestSupport.writeWAV(at: dir.appendingPathComponent("a.wav"), seconds: 2)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: stamp, .modificationDate: stamp],
                                              ofItemAtPath: url.path)
        let dates = ImportSupport.fileDates(at: url)
        #expect(abs((dates.creation ?? .distantPast).timeIntervalSince(stamp)) < 1)
        #expect(abs((dates.modification ?? .distantPast).timeIntervalSince(stamp)) < 1)
    }

    @Test func fileDatesOfMissingFileAreNil() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let dates = ImportSupport.fileDates(at: dir.appendingPathComponent("nope.wav"))
        #expect(dates.creation == nil)
        #expect(dates.modification == nil)
    }

    // MARK: - Type gate (§5.1)

    @Test func typeGateRejectsNonAudioExtensions() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let jpeg = dir.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: jpeg)

        #expect(!ImportSupport.conformsToAcceptedType(jpeg))
        #expect(throws: ImportError.notSupportedType(filename: "photo.jpg")) {
            try ImportSupport.validateType(jpeg)
        }
    }

    @Test func typeGateAcceptsWAV() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("memo.wav"), seconds: 2)
        #expect(ImportSupport.conformsToAcceptedType(wav))
        try ImportSupport.validateType(wav)
    }

    @Test func typeGateRejectsExtensionlessFile() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let blob = dir.appendingPathComponent("recording")
        try Data("not audio".utf8).write(to: blob)
        #expect(!ImportSupport.conformsToAcceptedType(blob))
    }

    // MARK: - Decode gate (§5.2)

    @Test func decodeGateAcceptsRealWAV() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("memo.wav"), seconds: 3)

        let info = try ImportSupport.inspectAudioFile(at: wav)
        #expect(info.sampleRate == 48_000)
        #expect(info.channelCount >= 1)
        #expect(info.frameLength > 0)
        #expect(abs(info.duration - 3) < 0.01)
        #expect(abs(info.duration - (try TestSupport.wavDuration(wav))) < 0.001)
    }

    /// A renamed JPEG passes the extension-based type gate and must die here.
    @Test func decodeGateRejectsRenamedJPEG() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let fake = dir.appendingPathComponent("REC0034.wav")
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        bytes.append(contentsOf: (0..<2_048).map { UInt8($0 % 251) })
        try Data(bytes).write(to: fake)

        #expect(throws: ImportError.notReadable(filename: "REC0034.wav")) {
            _ = try ImportSupport.inspectAudioFile(at: fake)
        }
    }

    @Test func decodeGateRejectsMissingFile() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        #expect(throws: ImportError.notReadable(filename: "ghost.wav")) {
            _ = try ImportSupport.inspectAudioFile(at: dir.appendingPathComponent("ghost.wav"))
        }
    }

    @Test func errorMessagesCarryTheFilename() {
        #expect(ImportError.notReadable(filename: "REC0034.wav").errorDescription
                == "Couldn't import REC0034.wav: not a readable WAV file")
        #expect(ImportError.noSpeech(filename: "REC0034.wav").errorDescription
                == "No speech detected in REC0034.wav")
    }

    // MARK: - Duration bounds (§5.3)

    @Test func subFloorWAVIsRejected() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let wav = try TestSupport.writeWAV(at: dir.appendingPathComponent("blip.wav"), seconds: 0.4)

        let info = try ImportSupport.inspectAudioFile(at: wav)
        #expect(info.duration < ImportSupport.minimumDuration)
        #expect(throws: ImportError.tooShort(filename: "blip.wav")) {
            try ImportSupport.validateDuration(info.duration, filename: "blip.wav")
        }
    }

    @Test func durationBoundsAreInclusiveAtTheEdges() throws {
        try ImportSupport.validateDuration(ImportSupport.minimumDuration, filename: "edge.wav")
        try ImportSupport.validateDuration(ImportSupport.maximumDuration, filename: "edge.wav")
        #expect(throws: ImportError.tooShort(filename: "edge.wav")) {
            try ImportSupport.validateDuration(ImportSupport.minimumDuration - 0.001, filename: "edge.wav")
        }
        #expect(throws: ImportError.tooLong(filename: "edge.wav")) {
            try ImportSupport.validateDuration(ImportSupport.maximumDuration + 1, filename: "edge.wav")
        }
    }

    // MARK: - Self-import guard (§5.4)

    @Test func selfImportGuardRefusesFilesInTomeDirectories() throws {
        let root = try TestSupport.makeTempDir()
        defer { TestSupport.remove(root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let outside = root.appendingPathComponent("Downloads", isDirectory: true)
        for d in [sessions, vault, outside] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }

        let artifact = sessions.appendingPathComponent("2026-08-08-100000.mic.wav")
        let retained = vault.appendingPathComponent("nested/memo.m4a")
        let userFile = outside.appendingPathComponent("REC0034.wav")

        #expect(throws: ImportError.selfImport(filename: artifact.lastPathComponent)) {
            try ImportSupport.validateNotSelfImport(artifact, protectedDirectories: [sessions, vault])
        }
        #expect(throws: ImportError.selfImport(filename: retained.lastPathComponent)) {
            try ImportSupport.validateNotSelfImport(retained, protectedDirectories: [sessions, vault])
        }
        try ImportSupport.validateNotSelfImport(userFile, protectedDirectories: [sessions, vault])
    }

    /// A sibling whose path merely shares a prefix string is not "inside".
    @Test func selfImportGuardIsComponentWise() throws {
        let root = try TestSupport.makeTempDir()
        defer { TestSupport.remove(root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let lookalike = root.appendingPathComponent("sessions-old", isDirectory: true)

        #expect(!ImportSupport.isContained(lookalike.appendingPathComponent("a.wav"), in: sessions))
        #expect(ImportSupport.isContained(sessions.appendingPathComponent("a.wav"), in: sessions))
        #expect(!ImportSupport.isContained(sessions, in: sessions), "a directory is not inside itself")
    }

    @Test func selfImportGuardWithNoProtectedDirectoriesAllowsEverything() throws {
        let root = try TestSupport.makeTempDir()
        defer { TestSupport.remove(root) }
        try ImportSupport.validateNotSelfImport(root.appendingPathComponent("a.wav"), protectedDirectories: [])
    }

    // MARK: - Handle construction (§6.2)

    /// The one legitimate post-processing divergence: an imported memo's
    /// voiceprint sidecar must not claim the recording user is among the prints.
    @Test func importedVoiceMemoHandleDoesNotClaimIncludesYou() {
        let snapshot = TestSupport.snapshot(filePath: URL(fileURLWithPath: "/tmp/note.md"))
        let mic = URL(fileURLWithPath: "/tmp/sessions/s1.mic.wav")

        let live = SessionHandle(
            id: "s1", sessionType: .voiceMemo, sourceApp: "Voice Memo",
            wavBufferPath: nil, micWavPath: mic,
            micFirstSampleTime: snapshot.sessionStartTime, systemFirstSampleTime: nil,
            transcript: snapshot
        )
        let imported = SessionHandle(
            id: "s2", sessionType: .voiceMemo, sourceApp: "Imported",
            wavBufferPath: nil, micWavPath: mic,
            micFirstSampleTime: snapshot.sessionStartTime, systemFirstSampleTime: nil,
            transcript: snapshot, origin: .imported
        )
        let call = SessionHandle(
            id: "s3", sessionType: .callCapture, sourceApp: "Zoom",
            wavBufferPath: URL(fileURLWithPath: "/tmp/sessions/s3.wav"), micWavPath: mic,
            micFirstSampleTime: snapshot.sessionStartTime, systemFirstSampleTime: nil,
            transcript: snapshot
        )

        #expect(live.origin == .live, "omitting origin keeps every existing call site live")
        #expect(live.voiceprintIncludesYou)
        #expect(imported.origin == .imported)
        #expect(!imported.voiceprintIncludesYou)
        #expect(!call.voiceprintIncludesYou)
    }
}
