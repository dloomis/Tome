import Foundation
import Testing
@testable import Tome

/// Session-GUID correlation protocol (SESSION_GUID_DESIGN.md): every session
/// carries a GUID — caller-supplied or Tome-minted — echoed from POST /start,
/// queryable per-session via GET /sessions/by-guid/{guid}/status, and stamped
/// into the transcript frontmatter and voiceprint sidecar.
///
/// Serialized for the same reason as APIServerTests: the HTTP tests bind real
/// loopback listeners and some assert against a shared main thread.
@Suite(.serialized)
struct SessionGuidTests {

    private struct PortFileTimeout: Error {}

    private func startServer(_ server: APIServer, portFile: URL) async throws -> URL {
        server.start()
        for _ in 0..<300 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8),
               let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               port != 0 {
                return URL(string: "http://127.0.0.1:\(port)")!
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PortFileTimeout()
    }

    private func request(
        _ base: URL, path: String, method: String = "GET", body: String? = nil
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 3
        if let body {
            req.httpBody = body.data(using: .utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private func makeServer(_ dir: URL) -> (APIServer, URL) {
        let portFile = dir.appendingPathComponent("api-port")
        return (APIServer(port: 0, portFileURL: portFile), portFile)
    }

    // MARK: - POST /start round-trip

    @Test func startEchoesSuppliedGuidAndSessionId() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)
        server.updateModelsReady(true)

        let guid = "3f1c9e2a-8b4d-4c6e-9f0a-2d7b5e8c1a4f"
        let (status, json) = try await request(
            base, path: "start", method: "POST",
            body: #"{"sessionGuid":"\#(guid)","suggestedFilename":"T1"}"#
        )
        #expect(status == 200)
        // Old-client compatibility: `ok` is still present and true.
        #expect(json["ok"] as? Bool == true)
        #expect(json["sessionGuid"] as? String == guid)
        #expect((json["sessionId"] as? String)?.hasPrefix("session_") == true)

        // The guid resolves immediately — before any MainActor pickup.
        let (byGuidStatus, byGuid) = try await request(base, path: "sessions/by-guid/\(guid)/status")
        #expect(byGuidStatus == 200)
        #expect(byGuid["sessionGuid"] as? String == guid)
        #expect(byGuid["state"] as? String == "recording")
        #expect(byGuid["startedAt"] as? String != nil)
        #expect(byGuid["sessionId"] as? String == json["sessionId"] as? String)

        // Global /status echoes the guid while recording.
        let (_, global) = try await request(base, path: "status")
        let recording = global["recording"] as? [String: Any]
        #expect(recording?["sessionGuid"] as? String == guid)
    }

    @Test func startMintsGuidWhenAbsentEmptyOrOversized() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)
        server.updateModelsReady(true)

        // No guid supplied → a fresh lowercase UUIDv4 is minted.
        let (status, json) = try await request(base, path: "start", method: "POST")
        #expect(status == 200)
        let minted = json["sessionGuid"] as? String
        #expect(minted != nil)
        #expect(UUID(uuidString: minted ?? "") != nil)
        #expect(minted == minted?.lowercased())

        // Walk this session out so the next start's gate opens.
        let sid = try #require(json["sessionId"] as? String)
        server.sessionDidStop(id: sid)
        server.sessionDidComplete(id: sid)

        // Empty and oversized guids are treated as absent, never echoed.
        let oversized = String(repeating: "x", count: 65)
        let (status2, json2) = try await request(
            base, path: "start", method: "POST", body: #"{"sessionGuid":"\#(oversized)"}"#
        )
        #expect(status2 == 200)
        let minted2 = try #require(json2["sessionGuid"] as? String)
        #expect(minted2 != oversized)
        #expect(UUID(uuidString: minted2) != nil)

        let sid2 = try #require(json2["sessionId"] as? String)
        server.sessionDidStop(id: sid2)
        server.sessionDidComplete(id: sid2)

        // A guid that would corrupt the YAML frontmatter it gets stamped into
        // (quotes, newlines) is treated as absent, not echoed.
        let (status3, json3) = try await request(
            base, path: "start", method: "POST", body: #"{"sessionGuid":"bad\"quote"}"#
        )
        #expect(status3 == 200)
        let minted3 = try #require(json3["sessionGuid"] as? String)
        #expect(!minted3.contains("\""))
        #expect(UUID(uuidString: minted3) != nil)
    }

    @Test func sessionsStartIncludesGuidForParity() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)
        server.updateModelsReady(true)

        let (status, json) = try await request(
            base, path: "sessions/start", method: "POST",
            body: #"{"type":"voiceMemo","sessionGuid":"my-key-01"}"#
        )
        #expect(status == 200)
        #expect(json["sessionGuid"] as? String == "my-key-01")
        #expect(json["status"] as? String == "starting")
    }

    // MARK: - by-guid lifecycle

    @Test func byGuidTracksStopCompleteWithFinalTranscriptPath() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)

        // Manual (menu-bar) sessions register through sessionDidStart.
        server.sessionDidStart(id: "session_A", guid: "guid-A", subject: "Standup")

        server.sessionDidStop(id: "session_A")
        let (_, transcribing) = try await request(base, path: "sessions/by-guid/guid-A/status")
        #expect(transcribing["state"] as? String == "transcribing")
        #expect(transcribing["startedAt"] as? String == nil)  // only while recording

        // Completion carries the FINAL path (post-rename, post-collision-suffix).
        let finalURL = URL(fileURLWithPath: "/vault/Meetings/Standup - Transcript-1.md")
        server.sessionDidComplete(id: "session_A", savedURL: finalURL)
        let (_, complete) = try await request(base, path: "sessions/by-guid/guid-A/status")
        #expect(complete["state"] as? String == "complete")
        #expect(complete["transcriptFilename"] as? String == "Standup - Transcript-1.md")
        #expect(complete["transcriptPath"] as? String == finalURL.path)
        #expect(complete["error"] as? String == nil)
    }

    @Test func byGuidReportsFailureAndFailedVerdictIsSticky() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)

        server.sessionDidStart(id: "session_F", guid: "guid-F")
        server.sessionDidStop(id: "session_F")
        server.sessionDidFail(id: "session_F", message: "Diarization failed: boom")

        let (_, failed) = try await request(base, path: "sessions/by-guid/guid-F/status")
        #expect(failed["state"] as? String == "failed")
        #expect(failed["error"] as? String == "Diarization failed: boom")

        // A late duplicate completion event must not flip the verdict.
        server.sessionDidComplete(id: "session_F", savedURL: URL(fileURLWithPath: "/x.md"))
        let (_, still) = try await request(base, path: "sessions/by-guid/guid-F/status")
        #expect(still["state"] as? String == "failed")
        #expect(still["error"] as? String == "Diarization failed: boom")
    }

    @Test func concurrentSessionsResolveIndependently() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)

        // Session A is post-processing while session B records — the supported
        // back-to-back overlap the guid table exists to disambiguate.
        server.sessionDidStart(id: "session_A", guid: "guid-A")
        server.sessionDidStop(id: "session_A")
        server.sessionDidStart(id: "session_B", guid: "guid-B")

        let (_, a) = try await request(base, path: "sessions/by-guid/guid-A/status")
        let (_, b) = try await request(base, path: "sessions/by-guid/guid-B/status")
        #expect(a["state"] as? String == "transcribing")
        #expect(b["state"] as? String == "recording")

        server.sessionDidComplete(id: "session_A", savedURL: URL(fileURLWithPath: "/vault/A.md"))
        let (_, a2) = try await request(base, path: "sessions/by-guid/guid-A/status")
        let (_, b2) = try await request(base, path: "sessions/by-guid/guid-B/status")
        #expect(a2["state"] as? String == "complete")
        #expect(b2["state"] as? String == "recording")
    }

    @Test func finishedSessionsEvictBeyondCapButLiveOnesSurvive() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)

        // A long-lived recording started before the churn must survive eviction.
        server.registerSession(guid: "guid-live", sessionId: "session_live")

        let overflow = APIServer.maxFinishedTrackedSessions + 5
        for i in 0..<overflow {
            server.registerSession(guid: "guid-\(i)", sessionId: "session_\(i)")
            server.sessionDidStop(id: "session_\(i)")
            server.sessionDidComplete(id: "session_\(i)")
        }

        // Oldest 5 finished are evicted; the newest cap-ful still resolve.
        for i in 0..<5 {
            let (status, _) = try await request(base, path: "sessions/by-guid/guid-\(i)/status")
            #expect(status == 404, "guid-\(i) should have been evicted")
        }
        for i in 5..<overflow {
            let (status, _) = try await request(base, path: "sessions/by-guid/guid-\(i)/status")
            #expect(status == 200, "guid-\(i) should still resolve")
        }
        let (liveStatus, live) = try await request(base, path: "sessions/by-guid/guid-live/status")
        #expect(liveStatus == 200)
        #expect(live["state"] as? String == "recording")
    }

    @Test func unknownGuidIs404() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let (server, portFile) = makeServer(dir)
        defer { server.stop() }
        let base = try await startServer(server, portFile: portFile)

        let (status, json) = try await request(base, path: "sessions/by-guid/never-seen/status")
        #expect(status == 404)
        #expect(json["error"] as? String == "unknown sessionGuid")
    }

    // MARK: - Artifacts

    @Test func loggerStampsGuidIntoFrontmatterAtSessionStart() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let logger = TranscriptLogger()
        let guid = "3f1c9e2a-8b4d-4c6e-9f0a-2d7b5e8c1a4f"
        let url = try await logger.startSession(
            sourceApp: "Test", vaultPath: vault.path, sessionGuid: guid
        )

        // Stamped immediately — a crash right now already leaves an identifiable note.
        let liveContent = try String(contentsOf: url, encoding: .utf8)
        #expect(liveContent.contains("session_guid: \"\(guid)\""))

        await logger.append(speaker: "You", text: "hello", timestamp: Date())
        let snapshot = try #require(await logger.endSession())
        #expect(snapshot.sessionGuid == guid)

        // Finalization (frontmatter rewrite + rename paths) must preserve the key.
        let savedURL = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snapshot)
        let finalContent = try String(contentsOf: savedURL, encoding: .utf8)
        #expect(finalContent.contains("session_guid: \"\(guid)\""))
    }

    @Test func guidSurvivesDiarizedRebuildAndRename() async throws {
        let vault = try TestSupport.makeTempDir()
        defer { TestSupport.remove(vault) }

        let guid = "rebuild-guid-01"
        var snapshot = try await TestSupport.makeSessionNote(
            vault: vault, sessionGuid: guid, suggestedFilename: "Renamed Note"
        )
        try TranscriptFinalizer.rebuildFromDiarizedSegments(
            snapshot: &snapshot,
            diarizedSegments: [
                ReTranscribedSegment(speaker: "Speaker 2", text: "hi there", startTime: 1.0)
            ]
        )
        let savedURL = try TranscriptFinalizer.finalizeFrontmatter(snapshot: snapshot)
        #expect(savedURL.lastPathComponent == "Renamed Note.md")
        let content = try String(contentsOf: savedURL, encoding: .utf8)
        #expect(content.contains("session_guid: \"\(guid)\""))
    }

    @Test func voiceprintSidecarCarriesGuidAtSchemaOne() throws {
        let diar = DiarizationOutput(
            segments: [DiarizedSegment(speakerId: "SPEAKER_0", startTime: 0, endTime: 2)],
            centroids: ["SPEAKER_0": [3, 4]]
        )
        let sidecar = try #require(VoiceprintSidecar.build(
            from: diar, source: "system", includesYou: false, sessionGuid: "vp-guid"
        ))
        #expect(sidecar.sessionGuid == "vp-guid")
        // Additive field — the on-disk schema does not bump.
        #expect(sidecar.schema == 1)

        // And it round-trips through the encoder.
        let data = try JSONEncoder().encode(sidecar)
        let decoded = try JSONDecoder().decode(VoiceprintSidecar.self, from: data)
        #expect(decoded.sessionGuid == "vp-guid")
    }

    @Test func schemaOneSessionSidecarWithoutGuidStillDecodes() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // Byte-for-byte what a pre-guid build wrote: schema 1, no sessionGuid.
        let legacy = """
        {
          "schema": 1,
          "sessionId": "session_2026-07-01_09-00-00",
          "transcriptPath": "/vault/Old.md",
          "startedAt": "2026-07-01T09:00:00Z",
          "sourceApp": "Teams",
          "sessionType": "callCapture",
          "sampleRate": 48000,
          "channels": 1,
          "bitsPerSample": 32,
          "appVersion": "1.4.0"
        }
        """
        let url = dir.appendingPathComponent("old.session.json")
        try legacy.data(using: .utf8)!.write(to: url)

        let decoded = try SessionSidecar.read(from: url)
        #expect(decoded.schema == 1)
        #expect(decoded.sessionGuid == nil)
        #expect(decoded.sessionId == "session_2026-07-01_09-00-00")
    }

    @Test func recoveryParsesGuidFromQuotedAndUnquotedFrontmatter() throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }

        // Quoted — as Tome writes it.
        let quoted = dir.appendingPathComponent("quoted.md")
        try "---\ntype: meeting\nsession_guid: \"abc-123\"\ntags: []\n---\nbody"
            .write(to: quoted, atomically: true, encoding: .utf8)
        #expect(Recovery.parseSessionGuid(fromTranscriptAt: quoted) == "abc-123")

        // Unquoted — after an external YAML round-trip strips the quotes.
        let unquoted = dir.appendingPathComponent("unquoted.md")
        try "---\ntype: meeting\nsession_guid: abc-456\ntags: []\n---\nbody"
            .write(to: unquoted, atomically: true, encoding: .utf8)
        #expect(Recovery.parseSessionGuid(fromTranscriptAt: unquoted) == "abc-456")

        // Pre-guid note — no key, no guess.
        let none = dir.appendingPathComponent("none.md")
        try "---\ntype: meeting\ntags: []\n---\nbody"
            .write(to: none, atomically: true, encoding: .utf8)
        #expect(Recovery.parseSessionGuid(fromTranscriptAt: none) == nil)
    }
}
