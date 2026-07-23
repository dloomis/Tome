import Foundation

enum TranscriptLoggerError: LocalizedError {
    case cannotCreateFile(String)
    var errorDescription: String? {
        switch self { case .cannotCreateFile(let p): return "Cannot create transcript at \(p)" }
    }
}

/// Writes structured markdown transcripts to the vault while a session is live.
/// Owns only the live `FileHandle` and the currently-buffering session state.
/// After `endSession()` returns a `TranscriptSessionSnapshot`, finalization runs
/// through `TranscriptFinalizer` pure functions — meaning the logger can immediately
/// begin a new session while post-processing of the previous one runs in the background.
actor TranscriptLogger {
    private var fileHandle: FileHandle?
    private var currentFilePath: URL?
    private var sessionStartTime: Date?
    private var sessionType: SessionType = .callCapture
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []
    /// Every utterance of the current session, never cleared until the next
    /// `startSession()`. `utteranceBuffer` alone can't recreate the note after an
    /// external deletion (it's cleared per flush), and this full in-memory copy is
    /// what lets `recreateTranscriptFile()` rebuild the whole body synchronously
    /// without reaching into the session JSONL from inside the actor.
    private var fullHistory: [(speaker: String, text: String, timestamp: Date)] = []
    private var suggestedFilename: String?
    private var filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss"
    private var sessionGuid: String = ""
    private var calendarEventId: String?

    /// Set when a flush/synchronize/reopen path fails or when the underlying file
    /// disappears (vault unmounted). Read by the UI through the periodic
    /// `flushIfNeeded()` poll and surfaced via `TranscriptionEngine.lastError`.
    var lastError: String?

    func setSuggestedFilename(_ name: String?) {
        suggestedFilename = name
    }

    /// `sessionGuid` is the session's correlation key, written into the note's
    /// frontmatter immediately (not at finalize time) so a crash-orphaned
    /// transcript already carries it. Defaults to a fresh mint so no path can
    /// produce an unstamped note.
    @discardableResult
    func startSession(
        sourceApp: String,
        vaultPath: String,
        sessionType: SessionType = .callCapture,
        sessionGuid: String = UUID().uuidString.lowercased(),
        calendarEventId: String? = nil,
        suggestedFilename: String? = nil,
        filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss",
        filenameTypeLabel: String? = nil
    ) throws -> URL {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.sessionType = sessionType
        self.speakersDetected = []
        self.sessionContext = ""
        self.utteranceBuffer = []
        self.fullHistory = []
        self.suggestedFilename = suggestedFilename
        self.filenameDateFormat = filenameDateFormat
        self.sessionGuid = sessionGuid
        self.calendarEventId = calendarEventId
        self.lastError = nil

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = sessionStartTime!

        // Heading label is purely cosmetic — keep the built-in names so the
        // YAML/markdown stays predictable for downstream tools. Filename label
        // is what the user actually sees in their vault, so use the override.
        let defaultTypeLabel = sessionType == .voiceMemo ? "Voice Memo" : "Call Recording"
        let chosenLabel = filenameTypeLabel ?? defaultTypeLabel
        // Empty override is valid ("date-only filenames"); preserve it. Sanitize
        // only non-empty user input, falling back to the default if sanitization
        // wipes everything (e.g. user typed only forbidden chars).
        let sanitizedTypeLabel: String
        if chosenLabel.isEmpty {
            sanitizedTypeLabel = ""
        } else {
            sanitizedTypeLabel = FilenameSanitizer.sanitize(chosenLabel) ?? defaultTypeLabel
        }

        let stem: String
        if let suggested = suggestedFilename,
           let cleaned = FilenameSanitizer.sanitize(suggested) {
            stem = cleaned
        } else {
            let datePrefix = FilenameSanitizer.formattedDate(now, format: filenameDateFormat)
            stem = sanitizedTypeLabel.isEmpty ? datePrefix : "\(datePrefix) \(sanitizedTypeLabel)"
        }
        // Never clobber an existing note. `createFile` truncates whatever is at the
        // path, so a repeated suggestedFilename (recurring meeting via the API) or
        // two sessions in the same second would silently destroy the earlier
        // transcript. Suffix "-1", "-2", … — same convention as the finalizer's
        // rename-collision handling.
        currentFilePath = Self.collisionFreeURL(in: directory, stem: stem)
        let filename = currentFilePath!.lastPathComponent

        let content = Self.documentHeader(
            sessionType: sessionType,
            sourceApp: sourceApp,
            filename: filename,
            sessionGuid: sessionGuid,
            startTime: now
        )

        let created = FileManager.default.createFile(atPath: currentFilePath!.path, contents: content.data(using: .utf8))
        guard created else { throw TranscriptLoggerError.cannotCreateFile(currentFilePath!.path) }
        fileHandle = try FileHandle(forWritingTo: currentFilePath!)
        fileHandle?.seekToEndOfFile()
        return currentFilePath!
    }

    /// First free `<stem>.md`, `<stem>-1.md`, `<stem>-2.md`, … in `directory`.
    /// Falls back to a UUID suffix rather than ever reusing an occupied path.
    private static func collisionFreeURL(in directory: URL, stem: String) -> URL {
        let first = directory.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for n in 1...100 {
            let candidate = directory.appendingPathComponent("\(stem)-\(n).md")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).md")
    }

    /// The live note's initial content: YAML frontmatter + headings through the
    /// `## Transcript` section marker. Shared by `startSession`, the mid-session
    /// self-heal (`recreateTranscriptFile`), and `TranscriptRebuilder`'s JSONL
    /// rebuilds — every recreated note must parse identically to one the live
    /// logger wrote, or the finalize/diarization regexes stop matching.
    static func documentHeader(
        sessionType: SessionType,
        sourceApp: String,
        filename: String,
        sessionGuid: String,
        startTime: Date
    ) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let dateStr = dateFmt.string(from: startTime)
        let timeStr = timeFmt.string(from: startTime)

        let isVoiceMemo = sessionType == .voiceMemo
        let headingLabel = isVoiceMemo ? "Voice Memo" : "Call Recording"
        let noteType = isVoiceMemo ? "fleeting" : "meeting"
        let logTag = isVoiceMemo ? "log/voice" : "log/meeting"
        let sourceTag = isVoiceMemo ? "source/voice" : "source/meeting"

        return """
---
type: \(noteType)
created: "\(dateStr)"
time: "\(timeStr)"
duration: "00:00"
source_app: "\(sourceApp)"
source_file: "\(filename)"
session_guid: "\(sessionGuid)"
attendees: []
context: ""
tags:
  - \(logTag)
  - status/inbox
  - \(sourceTag)
  - source/tome
---

# \(headingLabel) — \(dateStr) \(timeStr)

**Duration:** 00:00 | **Speakers:** 0

---

## Context



---

## Transcript

"""
    }

    /// Render utterances into the body format the live flush writes: a
    /// `**Speaker** (offset-seconds)` marker line, the text, and a blank line.
    static func renderUtterances(
        _ entries: [(speaker: String, text: String, timestamp: Date)],
        start: Date
    ) -> String {
        var lines = ""
        for entry in entries {
            let offset = entry.timestamp.timeIntervalSince(start)
            lines += "**\(entry.speaker)** (\(formatTimeOffset(offset)))\n"
            lines += "\(entry.text)\n\n"
        }
        return lines
    }

    /// Apply a session context to note content: patches the frontmatter
    /// `context:` field and fills the `## Context` body section. Shared by
    /// `updateContext` and the self-heal path (which must not lose a context
    /// applied before the note vanished).
    private static func applyingContext(_ text: String, to content: String) -> String {
        var content = content
        if let range = content.range(of: #"context: ".*""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "context: \(yamlQuote(text))")
        }
        if let contextStart = content.range(of: "## Context\n"),
           let contextEnd = content.range(of: "\n---\n\n## Transcript", range: contextStart.upperBound..<content.endIndex) {
            let replaceRange = contextStart.upperBound..<contextEnd.lowerBound
            content.replaceSubrange(replaceRange, with: "\n\(text)\n")
        }
        return content
    }

    func append(speaker: String, text: String, timestamp: Date) {
        // Keep "Them" as-is during recording so post-session diarization can find and replace it.
        // "You" is always kept as "You".
        let label = speaker == "You" ? "You" : "Them"
        speakersDetected.insert(label)
        utteranceBuffer.append((speaker: label, text: text, timestamp: timestamp))
        fullHistory.append((speaker: label, text: text, timestamp: timestamp))
        flushBuffer()  // Flush every utterance for crash safety
    }

    /// Periodic flush — call from a timer or at intervals. Also the timer-cadence
    /// leg of the disappearance self-heal: with no new utterances, `flushBuffer`'s
    /// own existence check never runs, so re-check (and recreate) here.
    func flushIfNeeded() {
        if !utteranceBuffer.isEmpty {
            flushBuffer()
        }
        if let path = currentFilePath, !FileManager.default.fileExists(atPath: path.path) {
            recreateTranscriptFile()
        }
    }

    private func flushBuffer() {
        guard let filePath = currentFilePath else { return }

        // Self-heal on external deletion (incident 2026-07-23): the user deleting
        // the meeting note in their vault pipeline unlinks the live transcript,
        // but APFS keeps the retained FileHandle valid — every write lands in an
        // orphaned inode and vanishes when the handle closes. Recreating from
        // `fullHistory` (which still includes the current buffer) turns that
        // silent total loss into a normal "unlinked meeting" that finalizes and
        // diarizes as usual.
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            recreateTranscriptFile()
            return
        }

        // A lost handle (e.g. reopen failure after a context rewrite) must not
        // strand utterances in the buffer forever — retry the reopen per flush.
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: filePath)
            fileHandle?.seekToEndOfFile()
        }
        guard let fileHandle, !utteranceBuffer.isEmpty else { return }

        // Per-line marker is the offset (in seconds, ms precision) from the session
        // start — the same t=0 the retained recording is anchored to — so it drops
        // straight into an Obsidian Media Extended `#t=` fragment.
        let start = sessionStartTime ?? utteranceBuffer.first?.timestamp ?? Date()
        let lines = Self.renderUtterances(utteranceBuffer, start: start)

        guard let data = lines.data(using: .utf8) else { return }
        fileHandle.seekToEndOfFile()
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
        } catch {
            // Keep buffered utterances so the next flush retries instead of losing them.
            lastError = "Transcript write failed: \(error.localizedDescription)"
            diagLogError("[LOGGER] flushBuffer write failed: \(error)")
            return
        }

        utteranceBuffer.removeAll()
    }

    /// The live note vanished out from under us — a *supported* external action
    /// (deleting the meeting note in the vault pipeline deletes Tome's transcript).
    /// Tome's contract is to carry on as an unlinked meeting: rebuild the whole
    /// note (frontmatter, context, full utterance history) at the same path and
    /// keep recording, so post-processing later runs unchanged. Failure leaves
    /// `lastError` set and everything retained in memory + the session JSONL;
    /// each subsequent flush retries, so a remounted vault heals on its own.
    @discardableResult
    private func recreateTranscriptFile() -> Bool {
        guard let filePath = currentFilePath, let startTime = sessionStartTime else { return false }
        try? fileHandle?.close()
        fileHandle = nil

        var isDir: ObjCBool = false
        let directory = filePath.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            // Whole folder gone — that's an unmount/eviction, not a note deletion.
            // Don't recreate the directory: on an unmounted volume that would
            // write into the empty mountpoint on the boot disk.
            lastError = "Transcript file disappeared — vault may be unmounted"
            diagLogError("[LOGGER] transcript folder missing — can't recreate \(filePath.lastPathComponent); \(fullHistory.count) utterances retained in memory + session JSONL")
            return false
        }

        var content = Self.documentHeader(
            sessionType: sessionType,
            sourceApp: sourceApp,
            filename: filePath.lastPathComponent,
            sessionGuid: sessionGuid,
            startTime: startTime
        )
        if !sessionContext.isEmpty {
            content = Self.applyingContext(sessionContext, to: content)
        }
        content += Self.renderUtterances(fullHistory, start: startTime)

        guard FileManager.default.createFile(atPath: filePath.path, contents: content.data(using: .utf8)) else {
            lastError = "Transcript file disappeared and couldn't be recreated"
            diagLogError("[LOGGER] recreate failed at \(filePath.path); \(fullHistory.count) utterances retained in memory + session JSONL")
            return false
        }
        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
        try? fileHandle?.synchronize()
        utteranceBuffer.removeAll()  // fullHistory ⊇ buffer; everything just landed
        lastError = nil
        diagLogError("[LOGGER] transcript disappeared externally — recreated \(filePath.lastPathComponent) with \(fullHistory.count) utterances, continuing as unlinked note")
        return true
    }

    func updateContext(_ text: String) {
        sessionContext = text
        guard let filePath = currentFilePath else { return }

        // Flush any buffered utterances first (this also self-heals a deleted
        // note), then fsync before close so any pending pages are durable before
        // the atomic-replace rewrites the file.
        flushBuffer()
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        guard let raw = try? String(contentsOf: filePath, encoding: .utf8) else { return }
        let content = Self.applyingContext(text, to: raw)

        // Atomic write — fsync the tmp file before replace so it lands on disk
        // before the rename. Without this, a crash between replace and the next
        // sync can leave a zero-byte file. The replace must only run if the tmp
        // write fully succeeded — swapping a partial tmp (disk full) over the
        // live transcript would destroy everything recorded so far. The tmp name
        // is unique per call: this runs while a previous session may be finalizing
        // tmp files into the same folder, and a shared name would let one
        // session's content replace the other's note.
        let tmpPath = filePath.deletingLastPathComponent()
            .appendingPathComponent(".tome_ctx_tmp-\(UUID().uuidString.prefix(8)).md")
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
            if let tmpHandle = try? FileHandle(forUpdating: tmpPath) {
                try? tmpHandle.synchronize()
                try? tmpHandle.close()
            }
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            lastError = "Context rewrite failed: \(error.localizedDescription)"
            diagLogError("[LOGGER] updateContext rewrite failed: \(error)")
            try? FileManager.default.removeItem(at: tmpPath)
        }

        // Reopen file handle; surface a missing handle so the timer-driven UI banner notices.
        fileHandle = try? FileHandle(forWritingTo: filePath)
        if fileHandle == nil {
            lastError = "Lost transcript handle after context update"
            diagLogError("[LOGGER] reopen failed after updateContext (next flush retries the reopen)")
        }
        fileHandle?.seekToEndOfFile()
    }

    private static func yamlQuote(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return "\"\(out)\""
    }

    /// Close the current session and return an immutable snapshot for post-processing.
    /// The logger is now free to begin a new session — the snapshot carries everything
    /// `TranscriptFinalizer` needs to finalize this session in the background.
    func endSession() -> TranscriptSessionSnapshot? {
        // Capture the stop moment first — duration is measured to here, not to whenever
        // the background queue eventually finalizes this session (which can be minutes
        // later behind diarization of an earlier session).
        let endTime = Date()
        flushBuffer()
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        guard let filePath = currentFilePath, let startTime = sessionStartTime else {
            resetState()
            return nil
        }

        let snapshot = TranscriptSessionSnapshot(
            filePath: filePath,
            sessionGuid: sessionGuid,
            calendarEventId: calendarEventId,
            sessionStartTime: startTime,
            sessionEndTime: endTime,
            speakersDetected: speakersDetected,
            sourceApp: sourceApp,
            sessionContext: sessionContext,
            suggestedFilename: suggestedFilename,
            filenameDateFormat: filenameDateFormat
        )

        resetState()
        return snapshot
    }

    private func resetState() {
        currentFilePath = nil
        sessionStartTime = nil
        sessionType = .callCapture
        speakersDetected = []
        sessionContext = ""
        utteranceBuffer = []
        fullHistory = []
        suggestedFilename = nil
        filenameDateFormat = "yyyy-MM-dd HH-mm-ss"
        sessionGuid = ""
        calendarEventId = nil
    }
}
