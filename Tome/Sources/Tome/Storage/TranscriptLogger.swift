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

    func setSuggestedFilename(_ name: String?) {
        suggestedFilename = name
    }

    func startSession(sourceApp: String, vaultPath: String, sessionType: SessionType = .callCapture, suggestedFilename: String? = nil) throws {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.sessionContext = ""
        self.utteranceBuffer = []
        self.suggestedFilename = suggestedFilename

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = sessionStartTime!
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let dateStr = dateFmt.string(from: now)
        let timeStr = timeFmt.string(from: now)

        let isVoiceMemo = sessionType == .voiceMemo
        let fileLabel = isVoiceMemo ? "Voice Memo" : "Call Recording"
        let noteType = isVoiceMemo ? "fleeting" : "meeting"
        let logTag = isVoiceMemo ? "log/voice" : "log/meeting"
        let sourceTag = isVoiceMemo ? "source/voice" : "source/meeting"

        let filename: String
        if let suggested = suggestedFilename, !suggested.isEmpty {
            let sanitized = suggested
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            filename = "\(sanitized).md"
        } else {
            filename = "\(fileFmt.string(from: now)) \(fileLabel).md"
        }
        currentFilePath = directory.appendingPathComponent(filename)

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

# \(fileLabel) — \(dateStr) \(timeStr)

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
    }

    private func flushBuffer() {
        guard let fileHandle, !utteranceBuffer.isEmpty else { return }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var lines = ""
        for entry in utteranceBuffer {
            lines += "**\(entry.speaker)** (\(timeFmt.string(from: entry.timestamp)))\n"
            lines += "\(entry.text)\n\n"
        }

        if let data = lines.data(using: .utf8) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }

        utteranceBuffer.removeAll()
    }

    func updateContext(_ text: String) {
        sessionContext = text
        guard let filePath = currentFilePath else { return }

        // Flush any buffered utterances first
        flushBuffer()
        try? fileHandle?.close()
        fileHandle = nil

        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Update frontmatter context field
        if let range = content.range(of: #"context: ".*""#, options: .regularExpression) {
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            content.replaceSubrange(range, with: "context: \"\(escaped)\"")
        }

        // Update ## Context body section
        if let contextStart = content.range(of: "## Context\n"),
           let contextEnd = content.range(of: "\n---\n\n## Transcript", range: contextStart.upperBound..<content.endIndex) {
            let replaceRange = contextStart.upperBound..<contextEnd.lowerBound
            content.replaceSubrange(replaceRange, with: "\n\(text)\n")
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)

        // Reopen file handle
        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    /// Close the current session and return an immutable snapshot for post-processing.
    /// The logger is now free to begin a new session — the snapshot carries everything
    /// `TranscriptFinalizer` needs to finalize this session in the background.
    func endSession() -> TranscriptSessionSnapshot? {
        flushBuffer()
        try? fileHandle?.close()
        fileHandle = nil

        guard let filePath = currentFilePath, let startTime = sessionStartTime else {
            resetState()
            return nil
        }

        let snapshot = TranscriptSessionSnapshot(
            filePath: filePath,
            sessionStartTime: startTime,
            speakersDetected: speakersDetected,
            sourceApp: sourceApp,
            sessionContext: sessionContext,
            suggestedFilename: suggestedFilename
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
    }
}
