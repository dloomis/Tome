import Foundation

/// Writes structured markdown transcripts to the vault.
actor TranscriptLogger {
    private var fileHandle: FileHandle?
    private var currentFilePath: URL?
    private var sessionStartTime: Date?
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []
    private var speakerCounter: Int = 1  // starts at 1, "You" is implicit

    // Map from raw speaker identity to display label
    private var speakerLabels: [String: String] = [:]

    // Retained from last session for post-session diarization rewrite
    private var lastSessionFilePath: URL?
    private var lastSessionStartTime: Date?

    func startSession(sourceApp: String, vaultPath: String, sessionType: SessionType = .callCapture) {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.speakerLabels = [:]
        self.speakerCounter = 1
        self.sessionContext = ""
        self.utteranceBuffer = []

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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

        let filename = "\(fileFmt.string(from: now)) \(fileLabel).md"
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

        FileManager.default.createFile(atPath: currentFilePath!.path, contents: content.data(using: .utf8))
        fileHandle = try? FileHandle(forWritingTo: currentFilePath!)
        fileHandle?.seekToEndOfFile()
    }

    func append(speaker: String, text: String, timestamp: Date) {
        let label = labelForSpeaker(speaker)
        speakersDetected.insert(label)
        utteranceBuffer.append((speaker: label, text: text, timestamp: timestamp))

        // Flush if buffer has accumulated enough
        if utteranceBuffer.count >= 5 {
            flushBuffer()
        }
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
        try? FileManager.default.removeItem(at: filePath)
        try? FileManager.default.moveItem(at: tmpPath, to: filePath)

        // Reopen file handle
        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    func endSession() {
        // Flush remaining buffer
        flushBuffer()

        // Close file handle immediately so next session can start
        try? fileHandle?.close()
        fileHandle = nil

        // Retain for post-session diarization
        lastSessionFilePath = currentFilePath
        lastSessionStartTime = sessionStartTime

        // Capture state for detached task
        let filePath = currentFilePath
        let startTime = sessionStartTime
        let speakers = speakersDetected
        let context = sessionContext

        // Reset state immediately
        currentFilePath = nil
        sessionStartTime = nil
        speakersDetected = []
        sessionContext = ""
        speakerLabels = [:]
        speakerCounter = 1

        // Detached task for frontmatter rewrite — doesn't block next startSession
        guard let filePath, let startTime else { return }

        Task.detached {
            await Self.rewriteFrontmatter(
                filePath: filePath,
                startTime: startTime,
                speakers: speakers,
                context: context
            )
        }
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        speakers: Set<String>,
        context: String
    ) async {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Calculate duration
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        // Build attendees array
        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = sortedSpeakers.isEmpty ? "[]" : "[\"\(sortedSpeakers.joined(separator: "\", \""))\"]"

        // Update frontmatter fields
        if let range = content.range(of: #"duration: "00:00""#) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        }
        if let range = content.range(of: "attendees: []") {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        // Update header line
        if let range = content.range(of: "**Duration:** 00:00 | **Speakers:** 0") {
            content.replaceSubrange(range, with: "**Duration:** \(durationStr) | **Speakers:** \(speakers.count)")
        }

        // Context-based file rename
        var finalPath = filePath
        if !context.isEmpty {
            let truncated = String(context.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            // Update source_file in content
            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)

        if finalPath != filePath {
            // Rename: remove old, move tmp to new name
            try? FileManager.default.removeItem(at: filePath)
            try? FileManager.default.moveItem(at: tmpPath, to: finalPath)
        } else {
            try? FileManager.default.removeItem(at: filePath)
            try? FileManager.default.moveItem(at: tmpPath, to: filePath)
        }
    }

    /// Rewrite the transcript file, replacing "Them" labels with diarized speaker IDs.
    /// Segments are (speakerId, startTimeSeconds, endTimeSeconds) from the offline diarizer.
    func rewriteWithDiarization(segments: [(speakerId: String, startTime: Float, endTime: Float)]) {
        guard let filePath = currentFilePath ?? lastSessionFilePath else { return }
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Build a map of unique diarization speaker IDs → friendly labels (Speaker 2, 3, etc.)
        var diarSpeakerMap: [String: String] = [:]
        var nextSpeakerNum = 2
        for seg in segments {
            if diarSpeakerMap[seg.speakerId] == nil {
                diarSpeakerMap[seg.speakerId] = "Speaker \(nextSpeakerNum)"
                nextSpeakerNum += 1
            }
        }

        // Parse transcript lines and re-attribute "Them" utterances based on timestamp overlap
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        // For each "**Them** (HH:mm:ss)" line, find the best matching diarization segment
        let pattern = #"\*\*Them\*\* \((\d{2}:\d{2}:\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        // Process in reverse so range offsets stay valid
        for match in matches.reversed() {
            let timeRange = match.range(at: 1)
            let timeStr = nsContent.substring(with: timeRange)

            // Parse the timestamp relative to session start
            guard let sessionStart = sessionStartTime ?? lastSessionStartTime else { continue }
            guard let utteranceDate = timeFmt.date(from: timeStr) else { continue }

            // Calculate seconds from session start (timestamps are clock times on the same day)
            let calendar = Calendar.current
            let startComponents = calendar.dateComponents([.hour, .minute, .second], from: sessionStart)
            let uttComponents = calendar.dateComponents([.hour, .minute, .second], from: utteranceDate)

            let startSeconds = (startComponents.hour ?? 0) * 3600 + (startComponents.minute ?? 0) * 60 + (startComponents.second ?? 0)
            let uttSeconds = (uttComponents.hour ?? 0) * 3600 + (uttComponents.minute ?? 0) * 60 + (uttComponents.second ?? 0)
            let offsetSeconds = Float(uttSeconds - startSeconds)

            // Find best matching segment
            var bestMatch: String?
            for seg in segments {
                if offsetSeconds >= seg.startTime && offsetSeconds <= seg.endTime {
                    bestMatch = diarSpeakerMap[seg.speakerId]
                    break
                }
            }

            // Also try closest segment if no exact overlap
            if bestMatch == nil {
                var minDist: Float = .infinity
                for seg in segments {
                    let midpoint = (seg.startTime + seg.endTime) / 2
                    let dist = abs(offsetSeconds - midpoint)
                    if dist < minDist && dist < 10 { // within 10 seconds
                        minDist = dist
                        bestMatch = diarSpeakerMap[seg.speakerId]
                    }
                }
            }

            if let label = bestMatch {
                let fullRange = match.range(at: 0)
                let replacement = "**\(label)** (\(timeStr))"
                content = (content as NSString).replacingCharacters(in: fullRange, with: replacement)
            }
        }

        // Update speaker count in header and frontmatter
        let allSpeakers = Set(diarSpeakerMap.values).union(["You"])
        if let range = content.range(of: #"\*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Speakers:** \(allSpeakers.count)")
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_diar_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: filePath)
        try? FileManager.default.moveItem(at: tmpPath, to: filePath)
    }

    private func labelForSpeaker(_ rawSpeaker: String) -> String {
        // "You" always maps to "You"
        if rawSpeaker.lowercased() == "you" { return "You" }

        // Check if we already assigned a label
        if let existing = speakerLabels[rawSpeaker] {
            return existing
        }

        // Assign new label
        speakerCounter += 1
        let label = "Speaker \(speakerCounter)"
        speakerLabels[rawSpeaker] = label
        return label
    }
}
