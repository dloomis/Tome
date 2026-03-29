import Foundation
import Network

/// Local HTTP API server for WhisperCal integration.
/// Binds to 127.0.0.1 only. Writes port to ~/Library/Application Support/Tome/api-port.
@Observable
@MainActor
final class APIServer {
    private var listener: NWListener?
    private let portFilePath: URL
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // References to app state (set via register())
    private weak var transcriptStore: TranscriptStore?
    private weak var transcriptionEngine: TranscriptionEngine?
    private var sessionStore: SessionStore?

    // Session control callbacks
    private var onStartSession: ((SessionType) -> Void)?
    private var onStopSession: (() -> Void)?

    // Session tracking (written by ContentView, read by API handlers)
    private(set) var currentSessionId: String?
    var sessionElapsed: Int = 0

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
        onStart: @escaping (SessionType) -> Void,
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
    }

    /// Mark a session as ended (called by ContentView after stopSession).
    func sessionDidEnd() {
        // Keep currentSessionId so status/transcript can still be queried.
        // It will be overwritten on next session start.
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
        case ("GET", "/health"):
            return handleHealth()

        case ("POST", "/sessions/start"):
            return handleStartSession(body: body)

        case ("POST", "/sessions/stop"):
            return handleStopSession(body: body)

        case ("GET", let p) where p.matchesPattern("/sessions/", suffix: "/status"):
            let id = p.extractSegment(prefix: "/sessions/", suffix: "/status")
            return handleSessionStatus(sessionId: id)

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

    private func handleStartSession(body: Data?) -> (Int, String) {
        guard let body,
              let req = try? JSONDecoder().decode(StartSessionRequest.self, from: body)
        else {
            return (400, #"{"error":"Invalid request body"}"#)
        }

        guard transcriptionEngine?.isRunning != true else {
            return (409, #"{"error":"A session is already in progress"}"#)
        }

        let type: SessionType = req.type == "voiceMemo" ? .voiceMemo : .callCapture
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        sessionElapsed = 0

        onStartSession?(type)

        return (200, encode(SessionStartResponse(
            sessionId: sessionId, status: "recording"
        )))
    }

    private func handleStopSession(body: Data?) -> (Int, String) {
        guard transcriptionEngine?.isRunning == true else {
            return (409, #"{"error":"No active session"}"#)
        }

        let sessionId = currentSessionId ?? "unknown"
        onStopSession?()

        return (200, encode(SessionStopResponse(
            sessionId: sessionId, status: "stopping"
        )))
    }

    private func handleSessionStatus(sessionId: String) -> (Int, String) {
        let isRecording = transcriptionEngine?.isRunning ?? false
        let assetStatus = transcriptionEngine?.assetStatus ?? "Ready"

        let status: String
        if isRecording && currentSessionId == sessionId {
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
            sinceDate = ISO8601DateFormatter().date(from: sinceStr)
        } else {
            sinceDate = nil
        }

        var sessions: [SessionSummary] = []
        for file in jsonlFiles where sessions.count < limit {
            guard let summary = Self.parseSessionSummary(from: file) else { continue }
            if let since = sinceDate,
               let summaryDate = ISO8601DateFormatter().date(from: summary.recordingStart),
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
                recordingStart: ISO8601DateFormatter().string(from: Date()),
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

        let isRecording = transcriptionEngine?.isRunning ?? false
        let metadata = TranscriptMetadata(
            title: nil,
            dateCreated: ISO8601DateFormatter().string(from: sessionStart),
            hasBeenDiarized: !isRecording,
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

        let metadata = TranscriptMetadata(
            title: nil,
            dateCreated: ISO8601DateFormatter().string(from: sessionStart),
            hasBeenDiarized: true,
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
            recordingStart: ISO8601DateFormatter().string(from: date),
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

        let parts = str.components(separatedBy: "\r\n\r\n")
        let headerSection = parts[0]
        let bodyStr = parts.count > 1 ? parts[1] : nil

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
