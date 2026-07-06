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
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []
    private var suggestedFilename: String?
    private var filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss"

    /// Set when a flush/synchronize/reopen path fails or when the underlying file
    /// disappears (vault unmounted). Read by the UI through the periodic
    /// `flushIfNeeded()` poll and surfaced via `TranscriptionEngine.lastError`.
    var lastError: String?

    func setSuggestedFilename(_ name: String?) {
        suggestedFilename = name
    }

    @discardableResult
    func startSession(
        sourceApp: String,
        vaultPath: String,
        sessionType: SessionType = .callCapture,
        suggestedFilename: String? = nil,
        filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss",
        filenameTypeLabel: String? = nil
    ) throws -> URL {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.sessionContext = ""
        self.utteranceBuffer = []
        self.suggestedFilename = suggestedFilename
        self.filenameDateFormat = filenameDateFormat
        self.lastError = nil

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = sessionStartTime!

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let dateStr = dateFmt.string(from: now)
        let timeStr = timeFmt.string(from: now)

        let isVoiceMemo = sessionType == .voiceMemo
        // Heading label is purely cosmetic — keep the built-in names so the
        // YAML/markdown stays predictable for downstream tools. Filename label
        // is what the user actually sees in their vault, so use the override.
        let headingLabel = isVoiceMemo ? "Voice Memo" : "Call Recording"
        let defaultTypeLabel = headingLabel
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
        let noteType = isVoiceMemo ? "fleeting" : "meeting"
        let logTag = isVoiceMemo ? "log/voice" : "log/meeting"
        let sourceTag = isVoiceMemo ? "source/voice" : "source/meeting"

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

        let content = """
---
type: \(noteType)
created: "\(dateStr)"
time: "\(timeStr)"
duration: "00:00"
source_app: "\(sourceApp)"
source_file: "\(filename)"
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

    func append(speaker: String, text: String, timestamp: Date) {
        // Keep "Them" as-is during recording so post-session diarization can find and replace it.
        // "You" is always kept as "You".
        let label = speaker == "You" ? "You" : "Them"
        speakersDetected.insert(label)
        utteranceBuffer.append((speaker: label, text: text, timestamp: timestamp))
        flushBuffer()  // Flush every utterance for crash safety
    }

    /// Periodic flush — call from a timer or at intervals
    func flushIfNeeded() {
        if !utteranceBuffer.isEmpty {
            flushBuffer()
        }
        // Vault-disappeared detection: surfaces unmount/eject within the timer cadence.
        if let path = currentFilePath, !FileManager.default.fileExists(atPath: path.path) {
            lastError = "Transcript file disappeared — vault may be unmounted"
        }
    }

    private func flushBuffer() {
        guard let fileHandle, !utteranceBuffer.isEmpty else { return }

        // Per-line marker is the offset (in seconds, ms precision) from the session
        // start — the same t=0 the retained recording is anchored to — so it drops
        // straight into an Obsidian Media Extended `#t=` fragment.
        let start = sessionStartTime ?? utteranceBuffer.first?.timestamp ?? Date()

        var lines = ""
        for entry in utteranceBuffer {
            let offset = entry.timestamp.timeIntervalSince(start)
            lines += "**\(entry.speaker)** (\(formatTimeOffset(offset)))\n"
            lines += "\(entry.text)\n\n"
        }

        guard let data = lines.data(using: .utf8) else { return }
        fileHandle.seekToEndOfFile()
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
        } catch {
            // Keep buffered utterances so the next flush retries instead of losing them.
            lastError = "Transcript write failed: \(error.localizedDescription)"
            diagLog("[LOGGER] flushBuffer write failed: \(error)")
            return
        }

        utteranceBuffer.removeAll()
    }

    func updateContext(_ text: String) {
        sessionContext = text
        guard let filePath = currentFilePath else { return }

        // Flush any buffered utterances first, then fsync before close so any
        // pending pages are durable before the atomic-replace rewrites the file.
        flushBuffer()
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Update frontmatter context field
        if let range = content.range(of: #"context: ".*""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "context: \(Self.yamlQuote(text))")
        }

        // Update ## Context body section
        if let contextStart = content.range(of: "## Context\n"),
           let contextEnd = content.range(of: "\n---\n\n## Transcript", range: contextStart.upperBound..<content.endIndex) {
            let replaceRange = contextStart.upperBound..<contextEnd.lowerBound
            content.replaceSubrange(replaceRange, with: "\n\(text)\n")
        }

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
            diagLog("[LOGGER] updateContext rewrite failed: \(error)")
            try? FileManager.default.removeItem(at: tmpPath)
        }

        // Reopen file handle; surface a missing handle so the timer-driven UI banner notices.
        fileHandle = try? FileHandle(forWritingTo: filePath)
        if fileHandle == nil {
            lastError = "Lost transcript handle after context update"
            diagLog("[LOGGER] reopen failed after updateContext")
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
        speakersDetected = []
        sessionContext = ""
        suggestedFilename = nil
        filenameDateFormat = "yyyy-MM-dd HH-mm-ss"
    }
}
