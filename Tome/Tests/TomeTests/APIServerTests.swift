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
}
