import Foundation
import Network

/// Lifecycle state for WhisperCal polling via GET /status.
enum SessionLifecycleState: String, Codable, Sendable {
    case idle
    case recording
    case transcribing
    case complete
}

/// Local HTTP API server for WhisperCal integration.
/// Binds to 127.0.0.1 only. Writes port to ~/Library/Application Support/Tome/api-port.
@MainActor
final class APIServer {
    private var listener: NWListener?
    private let portFilePath: URL
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let iso8601 = ISO8601DateFormatter()

    // References to app state (set via register())
    private weak var transcriptStore: TranscriptStore?
    private weak var transcriptionEngine: TranscriptionEngine?
    private var sessionStore: SessionStore?

    // Session control callbacks (4th param is suggestedFilename from WhisperCal)
    private var onStartSession: ((SessionType, String, MeetingContext?, String?) -> Void)?
    private var onStopSession: (() -> Void)?

    // Session tracking (written by ContentView, read by API handlers)
    private(set) var currentSessionId: String?
    var sessionElapsed: Int = 0
    private(set) var hasDiarizationCompleted: Bool = false
    private(set) var lifecycleState: SessionLifecycleState = .idle

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        portFilePath = appSupport.appendingPathComponent("Tome/api-port")
    }

    // MARK: - Registration

    /// Called by ContentView after TranscriptionEngine is initialized.
    func register(
        transcriptStore: TranscriptStore,
        transcriptionEngine: TranscriptionEngine,
        sessionStore: SessionStore,
        onStart: @escaping (SessionType, String, MeetingContext?, String?) -> Void,
        onStop: @escaping () -> Void
    ) {
        self.transcriptStore = transcriptStore
        self.transcriptionEngine = transcriptionEngine
        self.sessionStore = sessionStore
        self.onStartSession = onStart
        self.onStopSession = onStop
    }

    /// Mark a session as started (called by ContentView after startSession succeeds).
    func sessionDidStart(id: String) {
        currentSessionId = id
        lifecycleState = .recording
    }

    /// Mark that recording has stopped and post-processing has begun.
    func sessionDidStop() {
        lifecycleState = .transcribing
    }

    /// Mark diarization as complete for the current session.
    func diarizationDidComplete() {
        hasDiarizationCompleted = true
    }

    /// Mark that the transcript file has been finalized and written.
    func sessionDidComplete() {
        lifecycleState = .complete
        // Reset to idle after a short delay so /status callers can see "complete"
        Task {
            try? await Task.sleep(for: .seconds(5))
            if lifecycleState == .complete {
                lifecycleState = .idle
                currentSessionId = nil
            }
        }
    }

    // MARK: - Server Lifecycle

    func start() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: .any
            )
            listener = try NWListener(using: params)
        } catch {
            print("[APIServer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.acceptConnection(connection)
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        removePortFile()
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                writePortFile(port: port.rawValue)
                print("[APIServer] Listening on http://127.0.0.1:\(port.rawValue)")
            }
        case .failed(let error):
            print("[APIServer] Listener failed: \(error)")
            listener?.cancel()
            listener = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.start()
            }
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func acceptConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    await self.handleRequest(data, on: connection)
                } else if let error {
                    print("[APIServer] Receive error: \(error)")
                    connection.cancel()
                }
            }
        }
    }

    // MARK: - HTTP Request Handling

    private func handleRequest(_ data: Data, on connection: NWConnection) async {
        guard let request = Self.parseHTTP(data) else {
            send(connection: connection, status: 400, json: #"{"error":"Bad request"}"#)
            return
        }

        let corsHeaders = [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
        ]

        if request.method == "OPTIONS" {
            send(connection: connection, status: 204, json: "", extraHeaders: corsHeaders)
            return
        }

        // Strip /api/v1 prefix if present
        let fullPath = request.path
        let path = fullPath.hasPrefix("/api/v1")
            ? String(fullPath.dropFirst(7))
            : fullPath

        let (status, json) = await route(
            method: request.method, path: path, query: request.query, body: request.body
        )
        send(connection: connection, status: status, json: json, extraHeaders: corsHeaders)
    }

    // MARK: - Router

    private func route(
        method: String, path: String, query: [String: String], body: Data?
    ) async -> (Int, String) {
        switch (method, path) {
        case ("GET", "/"):
            return (200, Self.openAPISpec)

        case ("GET", "/health"):
            return handleHealth()

        // WhisperCal simplified endpoints
        case ("POST", "/start"):
            return handleWhisperCalStart(body: body)

        case ("POST", "/stop"):
            return handleWhisperCalStop()

        case ("GET", "/status"):
            return handleWhisperCalStatus()

        // Full session management endpoints
        case ("POST", "/sessions/start"):
            return handleStartSession(body: body)

        case ("POST", "/sessions/stop"):
            return handleStopSession(body: body)

        case ("GET", let p) where p.matchesPattern("/sessions/", suffix: "/status"):
            let id = p.extractSegment(prefix: "/sessions/", suffix: "/status")
            return await handleSessionStatus(sessionId: id)

        case ("GET", let p) where p.matchesPattern("/sessions/", suffix: "/transcript"):
            let id = p.extractSegment(prefix: "/sessions/", suffix: "/transcript")
            return await handleGetTranscript(sessionId: id)

        case ("GET", "/sessions"):
            return await handleListSessions(query: query)

        default:
            return (404, #"{"error":"Not found"}"#)
        }
    }

    // MARK: - Handlers

    private func handleHealth() -> (Int, String) {
        let isRecording = transcriptionEngine?.isRunning ?? false
        let statusStr = transcriptionEngine?.assetStatus ?? "Unknown"
        let modelsReady = statusStr == "Ready"
            || statusStr.contains("Transcribing")
            || statusStr.contains("Identifying")

        return (200, encode(HealthResponse(
            status: "ok",
            version: "1.0.0",
            isRecording: isRecording,
            modelsReady: modelsReady
        )))
    }

    // MARK: - WhisperCal Handlers

    private func handleWhisperCalStart(body: Data?) -> (Int, String) {
        guard transcriptionEngine?.isRunning != true,
              lifecycleState != .recording,
              lifecycleState != .transcribing else {
            return (409, #"{"error":"Already recording"}"#)
        }

        let req: WhisperCalStartRequest?
        if let body, !body.isEmpty {
            req = try? JSONDecoder().decode(WhisperCalStartRequest.self, from: body)
        } else {
            req = nil
        }

        let sessionId = SessionStore.generateSessionId()
        currentSessionId = sessionId
        sessionElapsed = 0
        hasDiarizationCompleted = false
        lifecycleState = .recording  // Set synchronously to prevent race with rapid duplicate requests

        onStartSession?(.callCapture, sessionId, req?.meetingContext, req?.suggestedFilename)

        return (200, #"{"ok":true}"#)
    }

    private func handleWhisperCalStop() -> (Int, String) {
        guard transcriptionEngine?.isRunning == true || lifecycleState == .recording else {
            return (409, #"{"error":"Not recording"}"#)
        }

        onStopSession?()

        return (200, #"{"ok":true}"#)
    }

    private func handleWhisperCalStatus() -> (Int, String) {
        return (200, #"{"state":"\#(lifecycleState.rawValue)"}"#)
    }

    // MARK: - Session Handlers

    private func handleStartSession(body: Data?) -> (Int, String) {
        guard let body,
              let req = try? JSONDecoder().decode(StartSessionRequest.self, from: body)
        else {
            return (400, #"{"error":"Invalid request body"}"#)
        }

        guard transcriptionEngine?.isRunning != true,
              lifecycleState != .recording,
              lifecycleState != .transcribing else {
            return (409, #"{"error":"A session is already in progress"}"#)
        }

        let type: SessionType
        switch req.type {
        case "voiceMemo": type = .voiceMemo
        case "callCapture": type = .callCapture
        default:
            return (400, #"{"error":"Invalid session type. Must be \"callCapture\" or \"voiceMemo\"."}"#)
        }

        let sessionId = SessionStore.generateSessionId()
        currentSessionId = sessionId
        sessionElapsed = 0
        hasDiarizationCompleted = false
        lifecycleState = .recording  // Set synchronously to prevent race with rapid duplicate requests

        onStartSession?(type, sessionId, req.meetingContext, nil)

        return (200, encode(SessionStartResponse(
            sessionId: sessionId, status: "starting"
        )))
    }

    private func handleStopSession(body: Data?) -> (Int, String) {
        guard transcriptionEngine?.isRunning == true else {
            return (409, #"{"error":"No active session"}"#)
        }

        // Validate session ID if provided in the request body
        if let body,
           let req = try? JSONDecoder().decode(StopSessionRequest.self, from: body),
           let current = currentSessionId,
           req.sessionId != current {
            return (409, encode(["error": "Session ID \"\(req.sessionId)\" does not match active session"]))
        }

        let sessionId = currentSessionId ?? "unknown"
        onStopSession?()

        return (200, encode(SessionStopResponse(
            sessionId: sessionId, status: "stopping"
        )))
    }

    private func handleSessionStatus(sessionId: String) async -> (Int, String) {
        let isCurrentSession = currentSessionId == sessionId

        // If not the current session, verify it exists as a stored file
        if !isCurrentSession {
            guard let sessionStore else {
                return (404, #"{"error":"Session not found"}"#)
            }
            let dir = await sessionStore.sessionsDirectoryURL
            let file = dir.appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else {
                return (404, #"{"error":"Session not found"}"#)
            }
            return (200, encode(SessionStatusResponse(
                sessionId: sessionId,
                status: "complete",
                elapsedSeconds: 0,
                speakerCount: 0,
                lineCount: 0
            )))
        }

        // Current session — report live status
        let isRecording = transcriptionEngine?.isRunning ?? false
        let assetStatus = transcriptionEngine?.assetStatus ?? "Ready"

        let status: String
        if isRecording {
            status = "recording"
        } else if assetStatus.contains("Identifying") || assetStatus.contains("Rewriting") {
            status = "diarizing"
        } else if assetStatus.contains("Finalizing") {
            status = "finalizing"
        } else if assetStatus.contains("Loading") || assetStatus.contains("Initializing") {
            status = "loading"
        } else {
            status = "complete"
        }

        let utterances = transcriptStore?.utterances ?? []
        let speakers = Set(utterances.map(\.speaker))

        return (200, encode(SessionStatusResponse(
            sessionId: sessionId,
            status: status,
            elapsedSeconds: sessionElapsed,
            speakerCount: speakers.count,
            lineCount: utterances.count
        )))
    }

    private func handleGetTranscript(sessionId: String) async -> (Int, String) {
        // Live session — read from TranscriptStore
        if let store = transcriptStore, currentSessionId == sessionId,
           !store.utterances.isEmpty
        {
            return (200, transcriptFromStore(store))
        }

        // Completed session — read JSONL file
        guard let sessionStore else {
            return (503, #"{"error":"Session store not available"}"#)
        }

        let dir = await sessionStore.sessionsDirectoryURL
        let file = dir.appendingPathComponent("\(sessionId).jsonl")

        guard FileManager.default.fileExists(atPath: file.path) else {
            return (404, #"{"error":"Session not found"}"#)
        }

        return (200, transcriptFromJSONL(file))
    }

    private func handleListSessions(query: [String: String]) async -> (Int, String) {
        guard let sessionStore else {
            return (503, #"{"error":"Session store not available"}"#)
        }

        let dir = await sessionStore.sessionsDirectoryURL
        let limit = Int(query["limit"] ?? "50") ?? 50

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return (200, encode(SessionListResponse(sessions: [])))
        }

        let jsonlFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        // Filter by since parameter
        let sinceDate: Date?
        if let sinceStr = query["since"] {
            sinceDate = iso8601.date(from: sinceStr)
        } else {
            sinceDate = nil
        }

        var sessions: [SessionSummary] = []
        for file in jsonlFiles where sessions.count < limit {
            guard let summary = Self.parseSessionSummary(from: file) else { continue }
            if let since = sinceDate,
               let summaryDate = iso8601.date(from: summary.recordingStart),
               summaryDate < since
            {
                continue
            }
            sessions.append(summary)
        }

        // Include live session if active
        if let sid = currentSessionId, transcriptionEngine?.isRunning == true {
            let liveSummary = SessionSummary(
                sessionId: sid,
                title: nil,
                recordingStart: iso8601.string(from: Date()),
                dateCreated: nil,
                durationSeconds: sessionElapsed,
                speakerCount: Set(transcriptStore?.utterances.map(\.speaker) ?? []).count,
                status: "recording"
            )
            sessions.insert(liveSummary, at: 0)
        }

        return (200, encode(SessionListResponse(sessions: sessions)))
    }

    // MARK: - Transcript Builders

    private func transcriptFromStore(_ store: TranscriptStore) -> String {
        let utterances = store.utterances
        let sessionStart = utterances.first?.timestamp ?? Date()

        var lines: [TranscriptLine] = []
        var speakerCounts: [String: Int] = [:]

        for u in utterances {
            let name = u.speaker == .you ? "You" : "Them"
            let ms = Int(u.timestamp.timeIntervalSince(sessionStart) * 1000)
            lines.append(TranscriptLine(speaker: name, text: u.text, startMs: max(0, ms)))
            speakerCounts[name, default: 0] += 1
        }

        let speakers = speakerCounts.map { name, count in
            APISpeakerInfo(
                name: name,
                id: name.lowercased(),
                isStub: name != "You",
                lineCount: count
            )
        }

        let metadata = TranscriptMetadata(
            title: nil,
            dateCreated: iso8601.string(from: sessionStart),
            hasBeenDiarized: hasDiarizationCompleted,
            durationSec: sessionElapsed,
            sourceApp: nil
        )

        return encode(TranscriptResponse(lines: lines, metadata: metadata, speakers: speakers))
    }

    private func transcriptFromJSONL(_ file: URL) -> String {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return encode(TranscriptResponse(lines: [], metadata: nil, speakers: []))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [SessionRecord] = []
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let record = try? decoder.decode(SessionRecord.self, from: data)
            {
                records.append(record)
            }
        }

        guard let first = records.first else {
            return encode(TranscriptResponse(lines: [], metadata: nil, speakers: []))
        }

        let sessionStart = first.timestamp
        var lines: [TranscriptLine] = []
        var speakerCounts: [String: Int] = [:]

        for r in records {
            let name = r.speaker == .you ? "You" : "Them"
            let ms = Int(r.timestamp.timeIntervalSince(sessionStart) * 1000)
            lines.append(TranscriptLine(speaker: name, text: r.text, startMs: max(0, ms)))
            speakerCounts[name, default: 0] += 1
        }

        let speakers = speakerCounts.map { name, count in
            APISpeakerInfo(
                name: name,
                id: name.lowercased(),
                isStub: name != "You",
                lineCount: count
            )
        }

        let durationSec = records.count >= 2
            ? Int(records.last!.timestamp.timeIntervalSince(sessionStart))
            : nil

        // Stored sessions are complete; diarization already ran if applicable.
        // Check if diarized by looking for speaker labels beyond "you"/"them".
        let hasDiarized = speakerCounts.keys.contains(where: { $0 != "You" && $0 != "Them" })
        let metadata = TranscriptMetadata(
            title: nil,
            dateCreated: iso8601.string(from: sessionStart),
            hasBeenDiarized: hasDiarized,
            durationSec: durationSec,
            sourceApp: nil
        )

        return encode(TranscriptResponse(lines: lines, metadata: metadata, speakers: speakers))
    }

    // MARK: - Session Summary Parsing

    private static func parseSessionSummary(from file: URL) -> SessionSummary? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("session_") else { return nil }

        let dateStr = String(stem.dropFirst(8))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = fmt.date(from: dateStr) else { return nil }

        // Quick parse for speaker count and duration
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let rawLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var speakers: Set<String> = []
        var lastTimestamp: Date?
        for line in rawLines {
            if let data = line.data(using: .utf8),
               let record = try? decoder.decode(SessionRecord.self, from: data)
            {
                speakers.insert(record.speaker.rawValue)
                lastTimestamp = record.timestamp
            }
        }

        let duration = lastTimestamp.map { Int($0.timeIntervalSince(date)) } ?? 0

        return SessionSummary(
            sessionId: stem,
            title: nil,
            recordingStart: ISO8601DateFormatter().string(from: date),  // static context — can't use instance formatter
            dateCreated: nil,
            durationSeconds: max(0, duration),
            speakerCount: speakers.count,
            status: "complete"
        )
    }

    // MARK: - HTTP Parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data?
    }

    private static func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        // Split at first \r\n\r\n only — body may contain that sequence
        let headerSection: String
        let bodyStr: String?
        if let separatorRange = str.range(of: "\r\n\r\n") {
            headerSection = String(str[..<separatorRange.lowerBound])
            let remainder = str[separatorRange.upperBound...]
            bodyStr = remainder.isEmpty ? nil : String(remainder)
        } else {
            headerSection = str
            bodyStr = nil
        }

        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let fullPath = String(requestParts[1])

        // Split path from query string
        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var query: [String: String] = [:]
        if pathComponents.count > 1 {
            for param in pathComponents[1].split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    query[key] = value
                }
            }
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let body = bodyStr?.isEmpty == false ? bodyStr?.data(using: .utf8) : nil
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    // MARK: - HTTP Response

    private func send(
        connection: NWConnection, status: Int, json: String, extraHeaders: [String] = []
    ) {
        let statusText =
            switch status {
            case 200: "OK"
            case 204: "No Content"
            case 400: "Bad Request"
            case 404: "Not Found"
            case 409: "Conflict"
            case 503: "Service Unavailable"
            default: "Unknown"
            }

        let bodyData = json.data(using: .utf8) ?? Data()
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        for h in extraHeaders { response += "\(h)\r\n" }
        response += "\r\n"

        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Port File

    private func writePortFile(port: UInt16) {
        let dir = portFilePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(port).write(to: portFilePath, atomically: true, encoding: .utf8)
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(at: portFilePath)
    }

    // MARK: - JSON Encoding

    private func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? jsonEncoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - OpenAPI Spec

    // swiftlint:disable line_length
    private static let openAPISpec = """
    {
      "openapi": "3.1.0",
      "info": {
        "title": "Tome API",
        "description": "Local API for Tome, a macOS meeting transcription app. Binds to 127.0.0.1 only.",
        "version": "1.0.0"
      },
      "servers": [
        { "url": "http://127.0.0.1:{port}/api/v1", "description": "Local server (port written to ~/Library/Application Support/Tome/api-port)" }
      ],
      "paths": {
        "/": {
          "get": {
            "summary": "OpenAPI specification",
            "description": "Returns this OpenAPI spec as JSON.",
            "responses": { "200": { "description": "OpenAPI JSON" } }
          }
        },
        "/health": {
          "get": {
            "summary": "Health check",
            "description": "Returns server status, whether models are loaded, and recording state.",
            "responses": {
              "200": {
                "description": "Health status",
                "content": { "application/json": { "schema": { "$ref": "#/components/schemas/HealthResponse" } } }
              }
            }
          }
        },
        "/start": {
          "post": {
            "summary": "Start call capture (WhisperCal)",
            "description": "Starts a new call capture recording. Returns 409 if already recording.",
            "requestBody": {
              "content": { "application/json": { "schema": { "$ref": "#/components/schemas/WhisperCalStartRequest" } } }
            },
            "responses": {
              "200": { "description": "Recording started", "content": { "application/json": { "schema": { "type": "object", "properties": { "ok": { "type": "boolean" } } } } } },
              "409": { "description": "Already recording" }
            }
          }
        },
        "/stop": {
          "post": {
            "summary": "Stop recording (WhisperCal)",
            "description": "Stops the active recording. Returns 409 if not recording.",
            "responses": {
              "200": { "description": "Recording stopped", "content": { "application/json": { "schema": { "type": "object", "properties": { "ok": { "type": "boolean" } } } } } },
              "409": { "description": "Not recording" }
            }
          }
        },
        "/status": {
          "get": {
            "summary": "Session lifecycle state (WhisperCal)",
            "description": "Returns the lifecycle state of the current or most recent session. WhisperCal polls this after calling /stop, waiting for 'complete'.",
            "responses": {
              "200": {
                "description": "Lifecycle state",
                "content": { "application/json": { "schema": { "type": "object", "properties": { "state": { "type": "string", "enum": ["idle", "recording", "transcribing", "complete"] } } } } }
              }
            }
          }
        },
        "/sessions": {
          "get": {
            "summary": "List sessions",
            "description": "Returns completed and active sessions, newest first.",
            "parameters": [
              { "name": "limit", "in": "query", "schema": { "type": "integer", "default": 50 }, "description": "Max sessions to return." },
              { "name": "since", "in": "query", "schema": { "type": "string", "format": "date-time" }, "description": "ISO 8601 date — only return sessions after this time." }
            ],
            "responses": {
              "200": { "description": "Session list", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SessionListResponse" } } } }
            }
          }
        },
        "/sessions/start": {
          "post": {
            "summary": "Start a recording session",
            "requestBody": {
              "required": true,
              "content": { "application/json": { "schema": { "$ref": "#/components/schemas/StartSessionRequest" } } }
            },
            "responses": {
              "200": { "description": "Session started", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SessionStartResponse" } } } },
              "400": { "description": "Invalid request body or session type" },
              "409": { "description": "A session is already in progress" }
            }
          }
        },
        "/sessions/stop": {
          "post": {
            "summary": "Stop the active recording session",
            "requestBody": {
              "content": { "application/json": { "schema": { "$ref": "#/components/schemas/StopSessionRequest" } } }
            },
            "responses": {
              "200": { "description": "Session stopping", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SessionStopResponse" } } } },
              "409": { "description": "No active session, or session ID mismatch" }
            }
          }
        },
        "/sessions/{sessionId}/status": {
          "get": {
            "summary": "Get session status",
            "description": "Returns the current state of a session: loading, recording, diarizing, finalizing, or complete.",
            "parameters": [
              { "name": "sessionId", "in": "path", "required": true, "schema": { "type": "string" } }
            ],
            "responses": {
              "200": { "description": "Session status", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SessionStatusResponse" } } } },
              "404": { "description": "Session not found" }
            }
          }
        },
        "/sessions/{sessionId}/transcript": {
          "get": {
            "summary": "Get session transcript",
            "description": "Returns transcript lines, speaker info, and metadata. Works for both live and completed sessions.",
            "parameters": [
              { "name": "sessionId", "in": "path", "required": true, "schema": { "type": "string" } }
            ],
            "responses": {
              "200": { "description": "Transcript data", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TranscriptResponse" } } } },
              "404": { "description": "Session not found" }
            }
          }
        }
      },
      "components": {
        "schemas": {
          "HealthResponse": {
            "type": "object",
            "properties": {
              "status": { "type": "string", "example": "ok" },
              "version": { "type": "string", "example": "1.0.0" },
              "isRecording": { "type": "boolean" },
              "modelsReady": { "type": "boolean" }
            }
          },
          "WhisperCalStartRequest": {
            "type": "object",
            "properties": {
              "suggestedFilename": { "type": "string", "description": "Output filename (without extension) for matching the transcript back to the meeting note." },
              "meetingContext": { "$ref": "#/components/schemas/MeetingContext" }
            }
          },
          "StartSessionRequest": {
            "type": "object",
            "required": ["type"],
            "properties": {
              "type": { "type": "string", "enum": ["callCapture", "voiceMemo"] },
              "meetingContext": { "$ref": "#/components/schemas/MeetingContext" }
            }
          },
          "MeetingContext": {
            "type": "object",
            "properties": {
              "subject": { "type": "string" },
              "attendees": { "type": "array", "items": { "type": "string" } },
              "calendarEventId": { "type": "string" },
              "startTime": { "type": "string", "format": "date-time" }
            }
          },
          "StopSessionRequest": {
            "type": "object",
            "properties": {
              "sessionId": { "type": "string", "description": "If provided, must match the active session." }
            }
          },
          "SessionStartResponse": {
            "type": "object",
            "properties": {
              "sessionId": { "type": "string" },
              "status": { "type": "string", "enum": ["starting"] }
            }
          },
          "SessionStopResponse": {
            "type": "object",
            "properties": {
              "sessionId": { "type": "string" },
              "status": { "type": "string", "enum": ["stopping"] }
            }
          },
          "SessionStatusResponse": {
            "type": "object",
            "properties": {
              "sessionId": { "type": "string" },
              "status": { "type": "string", "enum": ["loading", "recording", "diarizing", "finalizing", "complete"] },
              "elapsedSeconds": { "type": "integer" },
              "speakerCount": { "type": "integer" },
              "lineCount": { "type": "integer" }
            }
          },
          "SessionListResponse": {
            "type": "object",
            "properties": {
              "sessions": { "type": "array", "items": { "$ref": "#/components/schemas/SessionSummary" } }
            }
          },
          "SessionSummary": {
            "type": "object",
            "properties": {
              "sessionId": { "type": "string" },
              "title": { "type": "string" },
              "recordingStart": { "type": "string", "format": "date-time" },
              "dateCreated": { "type": "string", "format": "date-time" },
              "durationSeconds": { "type": "integer" },
              "speakerCount": { "type": "integer" },
              "status": { "type": "string" }
            }
          },
          "TranscriptResponse": {
            "type": "object",
            "properties": {
              "lines": { "type": "array", "items": { "$ref": "#/components/schemas/TranscriptLine" } },
              "metadata": { "$ref": "#/components/schemas/TranscriptMetadata" },
              "speakers": { "type": "array", "items": { "$ref": "#/components/schemas/SpeakerInfo" } }
            }
          },
          "TranscriptLine": {
            "type": "object",
            "properties": {
              "speaker": { "type": "string" },
              "text": { "type": "string" },
              "startMs": { "type": "integer" }
            }
          },
          "TranscriptMetadata": {
            "type": "object",
            "properties": {
              "title": { "type": "string" },
              "dateCreated": { "type": "string", "format": "date-time" },
              "hasBeenDiarized": { "type": "boolean" },
              "durationSec": { "type": "integer" },
              "sourceApp": { "type": "string" }
            }
          },
          "SpeakerInfo": {
            "type": "object",
            "properties": {
              "name": { "type": "string" },
              "id": { "type": "string" },
              "isStub": { "type": "boolean", "description": "True if this speaker has not been identified by diarization." },
              "lineCount": { "type": "integer" }
            }
          }
        }
      }
    }
    """
    // swiftlint:enable line_length
}

// MARK: - String Helpers for Path Matching

private extension String {
    func matchesPattern(_ prefix: String, suffix: String) -> Bool {
        hasPrefix(prefix) && hasSuffix(suffix) && count > prefix.count + suffix.count
    }

    func extractSegment(prefix: String, suffix: String) -> String {
        var s = self
        if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        return s
    }
}
