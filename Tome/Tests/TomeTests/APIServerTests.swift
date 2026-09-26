import Foundation
import Testing
@testable import Tome

/// Regression: the API must answer without an unblocked MainActor.
///
/// The launch orphan-recovery alert (`NSAlert.runModal()` in ContentView) parks
/// the main thread in a nested run loop, which starves main-queue dispatch and
/// every MainActor task. The original `@MainActor` APIServer ran its NWListener
/// on `.main` and hopped every byte through the MainActor, so GET /health hung
/// for as long as any modal alert or panel was up (verified 2026-07-09 in the
/// task-13 smoke test: `sample` showed the main thread in `-[NSAlert runModal]`
/// while curl timed out).
///
/// These tests hold the main thread hostage on a semaphore — the same starvation
/// a modal causes — and require the WhisperCal-critical endpoints to respond.
///
/// Serialized: each test blocks the shared main thread, so two of these running
/// concurrently would stall each other's setup.
@Suite(.serialized)
struct APIServerTests {

    private struct PortFileTimeout: Error {}

    /// Starts the server on an ephemeral loopback port and returns the base URL
    /// once the port file (written on listener-ready) names the assigned port.
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

    /// Parks the main thread on a semaphore until the returned semaphore is
    /// signalled — the same MainActor starvation `NSAlert.runModal()` causes.
    private func blockMainThread() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            entered.signal()
            release.wait()
        }
        // Wait until main is provably inside the block. Bounded so a broken
        // main queue fails the test instead of hanging the run.
        #expect(entered.wait(timeout: .now() + 5) == .success)
        return release
    }

    private func request(
        _ base: URL, path: String, method: String = "GET", timeout: TimeInterval = 3
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    @Test func healthRespondsWhileMainThreadIsBlocked() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))

        let release = blockMainThread()
        defer { release.signal() }

        let (status, json) = try await request(base, path: "health")
        #expect(status == 200)
        #expect(json["status"] as? String == "ok")
        // Nothing registered and no readiness pushed — must report not ready,
        // not hang.
        #expect(json["modelsReady"] as? Bool == false)
        #expect(json["isRecording"] as? Bool == false)
    }

    @Test func startModelGateRespondsWhileMainThreadIsBlocked() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))

        let release = blockMainThread()
        defer { release.signal() }

        // Models not ready → the gate must answer 503 without the MainActor.
        let (status, json) = try await request(base, path: "start", method: "POST")
        #expect(status == 503)
        #expect((json["error"] as? String)?.contains("not ready") == true)

        // /status is in WhisperCal's polling path — it must answer too.
        let (statusCode, statusJSON) = try await request(base, path: "status")
        #expect(statusCode == 200)
        #expect(statusJSON["state"] as? String == "idle")
    }

    @Test func startStopLifecycleWorksFromMirroredState() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))

        // ContentView pushes model readiness; recording state flows from /start.
        server.updateModelsReady(true)

        let (startStatus, startJSON) = try await request(base, path: "start", method: "POST")
        #expect(startStatus == 200)
        #expect(startJSON["ok"] as? Bool == true)

        let (statusCode, statusJSON) = try await request(base, path: "status")
        #expect(statusCode == 200)
        #expect(statusJSON["state"] as? String == "recording")

        // A second start while recording must 409 — the gate state is atomic.
        let (dupStatus, _) = try await request(base, path: "start", method: "POST")
        #expect(dupStatus == 409)

        let (stopStatus, _) = try await request(base, path: "stop", method: "POST")
        #expect(stopStatus == 200)
    }

    // MARK: - Single Record Button (auto mode) — spec §8

    /// POST with a JSON body. `request(_:path:)` sends no body, and
    /// `/sessions/start` requires one.
    private func post(
        _ base: URL, path: String, json body: String, timeout: TimeInterval = 3
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// Captures the `RecordingMode` the server hands to the registered
    /// `onStart` callback (which runs on the MainActor).
    @MainActor
    private final class StartRecorder {
        var modes: [RecordingMode] = []
    }

    /// Registers real (idle) app objects plus a recording `onStart`. The server
    /// holds the store/engine weakly, so the caller must keep the returned
    /// objects alive for the test's duration.
    @MainActor
    private func registerRecorder(
        on server: APIServer, sessionsDir: URL
    ) -> (StartRecorder, TranscriptStore, TranscriptionEngine) {
        let recorder = StartRecorder()
        let store = TranscriptStore()
        let engine = TranscriptionEngine(transcriptStore: store, asrCoordinator: ASRCoordinator())
        server.register(
            transcriptStore: store,
            transcriptionEngine: engine,
            sessionStore: SessionStore(directory: sessionsDir),
            onStart: { mode, _, _, _, _ in recorder.modes.append(mode) },
            onStop: {}
        )
        return (recorder, store, engine)
    }

    /// Polls the MainActor recorder until `onStart` has fired `count` times.
    private func awaitStarts(_ recorder: StartRecorder, count: Int) async throws -> [RecordingMode] {
        for _ in 0..<300 {
            let modes = await MainActor.run { recorder.modes }
            if modes.count >= count { return modes }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await MainActor.run { recorder.modes }
    }

    @Test func startSessionWithoutTypeDefaultsToAuto() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let (recorder, store, engine) = await registerRecorder(on: server, sessionsDir: dir)
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))
        server.updateModelsReady(true)

        let (status, json) = try await post(base, path: "api/v1/sessions/start", json: "{}")
        #expect(status == 200)
        #expect(json["status"] as? String == "starting")
        #expect(try await awaitStarts(recorder, count: 1) == [.auto])
        withExtendedLifetime((store, engine)) {}
    }

    @Test func startSessionAcceptsExplicitAuto() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let (recorder, store, engine) = await registerRecorder(on: server, sessionsDir: dir)
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))
        server.updateModelsReady(true)

        let (status, _) = try await post(base, path: "api/v1/sessions/start", json: #"{"type":"auto"}"#)
        #expect(status == 200)
        #expect(try await awaitStarts(recorder, count: 1) == [.auto])
        withExtendedLifetime((store, engine)) {}
    }

    @Test func startSessionPassesExplicitTypesThrough() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let (recorder, store, engine) = await registerRecorder(on: server, sessionsDir: dir)
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))
        server.updateModelsReady(true)

        let (status, json) = try await post(base, path: "api/v1/sessions/start", json: #"{"type":"voiceMemo"}"#)
        #expect(status == 200)
        #expect(try await awaitStarts(recorder, count: 1) == [.voiceMemo])

        // Walk the first session out of `recording` so the gate admits a second start.
        let firstId = try #require(json["sessionId"] as? String)
        server.sessionDidStop(id: firstId)
        let (status2, _) = try await post(base, path: "api/v1/sessions/start", json: #"{"type":"callCapture"}"#)
        #expect(status2 == 200)
        #expect(try await awaitStarts(recorder, count: 2) == [.voiceMemo, .callCapture])
        withExtendedLifetime((store, engine)) {}
    }

    @Test func startSessionRejectsUnknownType() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let (recorder, store, engine) = await registerRecorder(on: server, sessionsDir: dir)
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))
        server.updateModelsReady(true)

        let (status, json) = try await post(base, path: "api/v1/sessions/start", json: #"{"type":"meeting"}"#)
        #expect(status == 400)
        let message = try #require(json["error"] as? String)
        #expect(message.contains("auto"))
        // A rejected request must not start anything or occupy the gate.
        #expect(server.lifecycleState == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await MainActor.run { recorder.modes }.isEmpty)
        withExtendedLifetime((store, engine)) {}
    }

    @Test func sessionStatusExposesResolutionOnlyAfterRecording() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let (_, store, engine) = await registerRecorder(on: server, sessionsDir: dir)
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))

        let sid = "session_2026-09-26_10-00-00"
        let guid = "33333333-3333-4333-8333-333333333333"
        server.sessionDidStart(id: sid, guid: guid)

        // While recording: neither field present. (The per-id "recording" case
        // is covered below; here the registered engine is idle, so by-guid is
        // the authoritative recording-state probe.)
        let (guidStatus, guidJSON) = try await request(base, path: "api/v1/sessions/by-guid/\(guid)/status")
        #expect(guidStatus == 200)
        #expect(guidJSON["state"] as? String == "recording")
        #expect(guidJSON["sessionType"] == nil)
        #expect(guidJSON["resolution"] == nil)

        // Resolved before the stop, as ContentView.stopSession will call it.
        server.sessionDidResolve(id: sid, sessionType: .voiceMemo, resolution: "farEndSilent")
        server.sessionDidStop(id: sid)

        let (idStatus, idJSON) = try await request(base, path: "api/v1/sessions/\(sid)/status")
        #expect(idStatus == 200)
        #expect(idJSON["sessionType"] as? String == "voiceMemo")
        #expect(idJSON["resolution"] as? String == "farEndSilent")

        let (_, guidAfter) = try await request(base, path: "api/v1/sessions/by-guid/\(guid)/status")
        #expect(guidAfter["state"] as? String == "transcribing")
        #expect(guidAfter["sessionType"] as? String == "voiceMemo")
        #expect(guidAfter["resolution"] as? String == "farEndSilent")

        // Survives completion (until the 5s eviction).
        server.sessionDidComplete(id: sid)
        let (_, guidDone) = try await request(base, path: "api/v1/sessions/by-guid/\(guid)/status")
        #expect(guidDone["state"] as? String == "complete")
        #expect(guidDone["resolution"] as? String == "farEndSilent")
        withExtendedLifetime((store, engine)) {}
    }

    @Test func sessionStatusOmitsResolutionForAnotherSessionStillRecording() async throws {
        // Per-id path for a non-current session in `recording` (a newer session
        // took over currentSessionId): no resolution fields, even if one leaked.
        let dir = try TestSupport.makeTempDir()
        defer { TestSupport.remove(dir) }
        let server = APIServer(port: 0, portFileURL: dir.appendingPathComponent("api-port"))
        defer { server.stop() }
        let base = try await startServer(server, portFile: dir.appendingPathComponent("api-port"))

        let older = "session_2026-09-26_09-00-00"
        server.sessionDidStart(id: older)
        server.sessionDidStart(id: "session_2026-09-26_09-30-00")

        let (status, json) = try await request(base, path: "api/v1/sessions/\(older)/status")
        #expect(status == 200)
        #expect(json["status"] as? String == "recording")
        #expect(json["sessionType"] == nil)
        #expect(json["resolution"] == nil)
    }
}
