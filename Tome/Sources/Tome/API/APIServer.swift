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
///
/// Deliberately NOT on the MainActor: modal alerts and panels (`NSAlert.runModal`,
/// `NSOpenPanel.runModal`) spin nested run loops that starve main-queue dispatch —
/// the launch orphan-recovery alert froze GET /health for as long as it was up.
/// All networking runs on a private serial queue, and the endpoints WhisperCal
/// depends on (/health, /status, /start, /stop and their gates) are answered from
/// `state`, a lock-guarded mirror pushed synchronously from the MainActor. Only
/// live-session detail reads (asset status, in-memory utterances) hop to the
/// MainActor, and only while a session is active.
final class APIServer: @unchecked Sendable {

    // MARK: - Mirrored State

    /// Everything the MainActor-free endpoints answer from. Guarded by `lock`.
    /// `isRecording` and `modelsReady` mirror MainActor sources
    /// (`TranscriptionEngine.isRunning`, `ModelProvisioner.canStartRecording`)
    /// via the update pushes below; the session fields are written by the
    /// session mutators (called from ContentView) and by the /start handlers.
    private struct State {
        var currentSessionId: String?
        var sessionElapsed = 0
        var hasDiarizationCompleted = false
        /// Per-session state so `/sessions/{id}/status` can answer correctly even
        /// when a newer session is already recording. The top-level `lifecycleState`
        /// tracks the most recent session for `/status` backwards compatibility.
        var sessionStates: [String: SessionLifecycleState] = [:]
        var lifecycleState: SessionLifecycleState = .idle
        /// The active recording's subject/title and suggested filename, set at
        /// start and echoed from GET /status while recording or transcribing.
        /// Reset on each start (a no-context UI start clears them) and when the
        /// session goes idle.
        var recordingSubject: String?
        var recordingFilename: String?
        var isRecording = false
        var modelsReady = false
    }

    private let lock = NSLock()
    private var state = State()

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    // MARK: - App references

    /// MainActor-isolated objects. Written by `register()` (MainActor) and
    /// dereferenced ONLY inside `MainActor.run` closures — the class itself is
    /// nonisolated, so this isolation is by convention.
    private weak var transcriptStore: TranscriptStore?
    private weak var transcriptionEngine: TranscriptionEngine?

    // Guarded by `lock` (Sendable, so handlers may read them on the API queue).
    private var _sessionStore: SessionStore?
    private var _onStartSession: (@MainActor @Sendable (SessionType, String, MeetingContext?, String?) -> Void)?
    private var _onStopSession: (@MainActor @Sendable () -> Void)?

    // MARK: - Networking

    /// All listener/connection callbacks land here — never on `.main`, so the
    /// server keeps serving while a modal run loop starves main-queue dispatch.
    private let queue = DispatchQueue(label: "com.dloomis.tome.APIServer")
    private var listener: NWListener?  // guarded by `lock`
    private let port: UInt16
    private let portFilePath: URL
    private let iso8601 = ISO8601DateFormatter()  // thread-safe per docs

    /// `port` 0 binds an ephemeral port (tests); the assigned port is published
    /// via the port file either way. `portFileURL` overrides the Application
    /// Support location so tests don't clobber a running app's port file.
    init(port: UInt16 = 27080, portFileURL: URL? = nil) {
        self.port = port
        if let portFileURL {
            portFilePath = portFileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            portFilePath = appSupport.appendingPathComponent("Tome/api-port")
        }
    }

    // MARK: - Registration

    /// Called by ContentView after TranscriptionEngine is initialized.
    @MainActor
    func register(
        transcriptStore: TranscriptStore,
        transcriptionEngine: TranscriptionEngine,
        sessionStore: SessionStore,
        onStart: @escaping @MainActor @Sendable (SessionType, String, MeetingContext?, String?) -> Void,
        onStop: @escaping @MainActor @Sendable () -> Void
    ) {
        self.transcriptStore = transcriptStore
        self.transcriptionEngine = transcriptionEngine
        lock.lock()
        _sessionStore = sessionStore
        _onStartSession = onStart
        _onStopSession = onStop
        lock.unlock()
    }

    // MARK: - State pushes from the MainActor

    /// ContentView pushes `TranscriptionEngine.isRunning` changes here so
    /// /health and the start/stop gates answer without touching the MainActor.
    func updateIsRecording(_ running: Bool) {
        withState { $0.isRecording = running }
    }

    /// ContentView pushes `ModelProvisioner.canStartRecording` changes here.
    /// The value can be a render cycle stale; the authoritative re-check still
    /// happens in ContentView.startSession on the MainActor.
    func updateModelsReady(_ ready: Bool) {
        withState { $0.modelsReady = ready }
    }

    /// Seconds elapsed in the current session, ticked by ContentView's timer.
    var sessionElapsed: Int {
        get { withState { $0.sessionElapsed } }
        set { withState { $0.sessionElapsed = newValue } }
    }

    var currentSessionId: String? {
        withState { $0.currentSessionId }
    }

    var lifecycleState: SessionLifecycleState {
        withState { $0.lifecycleState }
    }

    /// Mark a session as started (called by ContentView after startSession succeeds).
    /// `subject`/`suggestedFilename` are the resolved recording identity (API context,
    /// else autodetected, else nil) echoed by GET /status; passing them here also
    /// clears any stale values from a prior session on a no-context UI start.
    func sessionDidStart(id: String, subject: String? = nil, suggestedFilename: String? = nil) {
        withState { s in
            s.currentSessionId = id
            s.sessionStates[id] = .recording
            s.lifecycleState = .recording
            s.hasDiarizationCompleted = false
            s.recordingSubject = subject
            s.recordingFilename = suggestedFilename
        }
    }

    /// Mark that recording has stopped for a specific session — its post-processing
    /// has been handed off to the background queue. The `id` is required because a
    /// newer session may already be starting concurrently.
    func sessionDidStop(id: String) {
        withState { s in
            s.sessionStates[id] = .transcribing
            if s.currentSessionId == id {
                s.lifecycleState = .transcribing
            }
        }
    }

    /// Mark diarization as complete for the most recent session. Kept for the
    /// `hasBeenDiarized` field on live transcript responses.
    func diarizationDidComplete() {
        withState { $0.hasDiarizationCompleted = true }
    }

    /// Mark that a specific session's transcript file has been finalized. The `id`
    /// is required because a different session may be recording when this fires
    /// from the background queue's completion event.
    func sessionDidComplete(id: String) {
        withState { s in
            s.sessionStates[id] = .complete
            // Only advance the top-level lifecycle if this is the most recent session.
            // A newer session's `.recording` takes precedence.
            if s.lifecycleState != .recording {
                s.lifecycleState = .complete
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            withState { s in
                s.sessionStates.removeValue(forKey: id)
                if s.lifecycleState == .complete && s.currentSessionId == id {
                    s.lifecycleState = .idle
                    s.currentSessionId = nil
                    s.recordingSubject = nil
                    s.recordingFilename = nil
                } else if s.lifecycleState == .complete {
                    // This was an older session's completion; don't touch currentSessionId.
                    s.lifecycleState = .idle
                }
            }
        }
    }

    // MARK: - Server Lifecycle

    func start() {
        let newListener: NWListener
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
            )
            newListener = try NWListener(using: params)
            listener = newListener
        } catch {
            lock.unlock()
            diagLog("[APIServer] Failed to create listener: \(error)")
            return
        }
        lock.unlock()

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }
        newListener.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
        removePortFile()
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = lock.withLock { listener?.port }
            if let port {
                writePortFile(port: port.rawValue)
                diagLog("[APIServer] Listening on http://127.0.0.1:\(port.rawValue)")
            }
        case .failed(let error):
            diagLog("[APIServer] Listener failed: \(error)")
            lock.lock()
            listener?.cancel()
            listener = nil
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.start()
            }
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func acceptConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    /// Accumulate receives until the request is complete — headers plus the
    /// declared Content-Length body. A single receive() is not enough: a request
    /// split across TCP segments would otherwise parse as malformed and 400.
    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let error {
                diagLog("[APIServer] Receive error: \(error)")
                connection.cancel()
                return
            }
            switch Self.requestCompleteness(buffer) {
            case .complete:
                // Handlers are async (session-store actor, live-session MainActor
                // reads); state they touch is lock-guarded, so leaving the
                // connection queue is safe.
                Task { await self.handleRequest(buffer, on: connection) }
            case .tooLarge:
                self.send(connection: connection, status: 413, json: #"{"error": "Request too large"}"#)
            case .needsMore where !isComplete:
                self.receiveRequest(on: connection, accumulated: buffer)
            case .needsMore:
                // Peer closed before sending a complete request.
                connection.cancel()
            }
        }
    }

    private enum RequestCompleteness { case complete, needsMore, tooLarge }

    /// 1 MB cap — far above any legitimate request to this local API, and low
    /// enough that a broken client can't grow the buffer without bound.
    private static let maxRequestBytes = 1_048_576

    private static func requestCompleteness(_ data: Data) -> RequestCompleteness {
        if data.count > maxRequestBytes { return .tooLarge }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return .needsMore }
        // Complete once the declared Content-Length has arrived (0 if absent).
        var contentLength = 0
        if let headerStr = String(data: data[..<separator.lowerBound], encoding: .utf8) {
            for line in headerStr.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }
        if contentLength > maxRequestBytes { return .tooLarge }
        return data.count - separator.upperBound >= contentLength ? .complete : .needsMore
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
        let (isRecording, modelsReady) = withState { ($0.isRecording, $0.modelsReady) }
        return (200, encode(HealthResponse(
            status: "ok",
            version: "1.0.0",
            isRecording: isRecording,
            modelsReady: modelsReady
        )))
    }

    // MARK: - WhisperCal Handlers

    private func handleWhisperCalStart(body: Data?) -> (Int, String) {
        let req: WhisperCalStartRequest?
        if let body, !body.isEmpty {
            req = try? JSONDecoder().decode(WhisperCalStartRequest.self, from: body)
        } else {
            req = nil
        }

        let sessionId = SessionStore.generateSessionId()

        // One critical section: the gate check and the state transition are
        // atomic, so rapid duplicate requests can't both pass, and a /status
        // poll landing before the MainActor picks up onStartSession already
        // sees .recording. `.transcribing` is NOT a blocker — post-processing
        // of a previous session runs in the background so a new recording can
        // start immediately.
        enum Gate { case alreadyRecording, notReady, accepted }
        let gate: Gate = withState { s in
            if s.isRecording || s.lifecycleState == .recording { return .alreadyRecording }
            guard s.modelsReady else { return .notReady }
            s.currentSessionId = sessionId
            s.sessionElapsed = 0
            s.hasDiarizationCompleted = false
            s.lifecycleState = .recording
            s.recordingSubject = req?.meetingContext?.subject
            s.recordingFilename = req?.suggestedFilename
            return .accepted
        }
        switch gate {
        case .alreadyRecording:
            return (409, #"{"error":"Already recording"}"#)
        case .notReady:
            return (503, #"{"error":"Transcription model not ready"}"#)
        case .accepted:
            break
        }

        let onStart = lock.withLock { _onStartSession }
        let context = req?.meetingContext
        let filename = req?.suggestedFilename
        Task { @MainActor in
            onStart?(.callCapture, sessionId, context, filename)
        }

        return (200, #"{"ok":true}"#)
    }

    private func handleWhisperCalStop() -> (Int, String) {
        guard withState({ $0.isRecording || $0.lifecycleState == .recording }) else {
            return (409, #"{"error":"Not recording"}"#)
        }

        let onStop = lock.withLock { _onStopSession }
        Task { @MainActor in onStop?() }

        return (200, #"{"ok":true}"#)
    }

    private func handleWhisperCalStatus() -> (Int, String) {
        // Echo the active recording's identity while a session is in flight, so the
        // caller can show *which* meeting is recording. Omitted when idle/complete,
        // or when there's no subject/filename to report.
        let (lifecycle, subject, filename) = withState {
            ($0.lifecycleState, $0.recordingSubject, $0.recordingFilename)
        }
        let recording: WhisperCalRecordingInfo?
        if lifecycle == .recording || lifecycle == .transcribing,
           subject != nil || filename != nil {
            recording = WhisperCalRecordingInfo(
                subject: subject, suggestedFilename: filename
            )
        } else {
            recording = nil
        }
        return (200, encode(WhisperCalStatusResponse(
            state: lifecycle.rawValue, recording: recording
        )))
    }

    // MARK: - Session Handlers

    private func handleStartSession(body: Data?) -> (Int, String) {
        guard let body,
              let req = try? JSONDecoder().decode(StartSessionRequest.self, from: body)
        else {
            return (400, #"{"error":"Invalid request body"}"#)
        }

        let type: SessionType
        switch req.type {
        case "voiceMemo": type = .voiceMemo
        case "callCapture": type = .callCapture
        default:
            return (400, #"{"error":"Invalid session type. Must be \"callCapture\" or \"voiceMemo\"."}"#)
        }

        let sessionId = SessionStore.generateSessionId()

        // Same atomic gate-and-transition as handleWhisperCalStart.
        enum Gate { case alreadyRecording, notReady, accepted }
        let gate: Gate = withState { s in
            if s.isRecording || s.lifecycleState == .recording { return .alreadyRecording }
            guard s.modelsReady else { return .notReady }
            s.currentSessionId = sessionId
            s.sessionElapsed = 0
            s.hasDiarizationCompleted = false
            s.lifecycleState = .recording
            s.recordingSubject = req.meetingContext?.subject
            s.recordingFilename = nil
            return .accepted
        }
        switch gate {
        case .alreadyRecording:
            return (409, #"{"error":"A session is already in progress"}"#)
        case .notReady:
            return (503, #"{"error":"Transcription model not ready"}"#)
        case .accepted:
            break
        }

        let onStart = lock.withLock { _onStartSession }
        let context = req.meetingContext
        Task { @MainActor in
            onStart?(type, sessionId, context, nil)
        }

        return (200, encode(SessionStartResponse(
            sessionId: sessionId, status: "starting"
        )))
    }

    private func handleStopSession(body: Data?) -> (Int, String) {
        let (isRecording, currentId) = withState { ($0.isRecording, $0.currentSessionId) }
        guard isRecording else {
            return (409, #"{"error":"No active session"}"#)
        }

        // Validate session ID if provided in the request body
        if let body,
           let req = try? JSONDecoder().decode(StopSessionRequest.self, from: body),
           let current = currentId,
           req.sessionId != current {
            return (409, encode(["error": "Session ID \"\(req.sessionId)\" does not match active session"]))
        }

        let sessionId = currentId ?? "unknown"
        let onStop = lock.withLock { _onStopSession }
        Task { @MainActor in onStop?() }

        return (200, encode(SessionStopResponse(
            sessionId: sessionId, status: "stopping"
        )))
    }

    private func handleSessionStatus(sessionId: String) async -> (Int, String) {
        let (isCurrentSession, perSessionState, elapsed) = withState {
            ($0.currentSessionId == sessionId, $0.sessionStates[sessionId], $0.sessionElapsed)
        }

        // Per-session state takes precedence over file-based lookup — it reflects
        // in-flight post-processing for sessions that just finished recording.
        if let state = perSessionState, !isCurrentSession {
            return (200, encode(SessionStatusResponse(
                sessionId: sessionId,
                status: state.rawValue,  // "transcribing" or "complete"
                elapsedSeconds: 0,
                speakerCount: 0,
                lineCount: 0
            )))
        }

        // If not the current session and no in-flight state, verify it exists as a stored file
        if !isCurrentSession {
            guard let sessionStore = lock.withLock({ _sessionStore }) else {
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

        // Current session — live status lives on the MainActor (engine + store).
        // This is the one status path that can wait on a busy MainActor; the
        // WhisperCal polling endpoints above never do.
        let (isRecording, assetStatus, speakerCount, lineCount) = await MainActor.run {
            () -> (Bool, String, Int, Int) in
            let utterances = self.transcriptStore?.utterances ?? []
            return (
                self.transcriptionEngine?.isRunning ?? false,
                self.transcriptionEngine?.assetStatus ?? "Ready",
                Set(utterances.map(\.speaker)).count,
                utterances.count
            )
        }

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

        return (200, encode(SessionStatusResponse(
            sessionId: sessionId,
            status: status,
            elapsedSeconds: elapsed,
            speakerCount: speakerCount,
            lineCount: lineCount
        )))
    }

    private func handleGetTranscript(sessionId: String) async -> (Int, String) {
        // Live session — snapshot the MainActor store, then build the response
        // off it (Utterance is Sendable).
        if withState({ $0.currentSessionId == sessionId }) {
            let utterances = await MainActor.run { self.transcriptStore?.utterances ?? [] }
            if !utterances.isEmpty {
                return (200, transcriptFromUtterances(utterances))
            }
        }

        // Completed session — read JSONL file
        guard let sessionStore = lock.withLock({ _sessionStore }) else {
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
        guard let sessionStore = lock.withLock({ _sessionStore }) else {
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

        // Include live session if active. The speaker count needs the MainActor
        // store — hop only while actually recording, so an idle list never waits.
        let (currentId, elapsed, isRecording) = withState {
            ($0.currentSessionId, $0.sessionElapsed, $0.isRecording)
        }
        if let sid = currentId, isRecording {
            let speakerCount = await MainActor.run {
                Set(self.transcriptStore?.utterances.map(\.speaker) ?? []).count
            }
            let liveSummary = SessionSummary(
                sessionId: sid,
                title: nil,
                recordingStart: iso8601.string(from: Date()),
                dateCreated: nil,
                durationSeconds: elapsed,
                speakerCount: speakerCount,
                status: "recording"
            )
            sessions.insert(liveSummary, at: 0)
        }

        return (200, encode(SessionListResponse(sessions: sessions)))
    }

    // MARK: - Transcript Builders

    private func transcriptFromUtterances(_ utterances: [Utterance]) -> String {
        let (hasDiarized, elapsed) = withState {
            ($0.hasDiarizationCompleted, $0.sessionElapsed)
        }
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
            hasBeenDiarized: hasDiarized,
            durationSec: elapsed,
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
            case 413: "Payload Too Large"
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
        // Fresh encoder per call: encode runs on the API queue and on detached
        // handler tasks — no shared mutable instance.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
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
              "409": { "description": "Already recording" },
              "503": { "description": "Transcription model not ready" }
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
            "description": "Returns the lifecycle state of the current or most recent session. WhisperCal polls this after calling /stop, waiting for 'complete'. While recording (or transcribing), also echoes the active recording's subject/suggestedFilename so the caller can show which meeting is captured; the 'recording' object is omitted when idle/complete.",
            "responses": {
              "200": {
                "description": "Lifecycle state, plus the active recording's identity while in flight.",
                "content": { "application/json": { "schema": { "type": "object", "properties": { "state": { "type": "string", "enum": ["idle", "recording", "transcribing", "complete"] }, "recording": { "$ref": "#/components/schemas/RecordingInfo" } } } } }
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
              "409": { "description": "A session is already in progress" },
              "503": { "description": "Transcription model not ready" }
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
          "RecordingInfo": {
            "type": "object",
            "description": "The active recording's identity, present on /status only while recording or transcribing.",
            "properties": {
              "subject": { "type": "string", "description": "Subject/title of the meeting being recorded, from the start request's meetingContext (or Tome's autodetection)." },
              "suggestedFilename": { "type": "string", "description": "The suggestedFilename supplied at start, if any." }
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
