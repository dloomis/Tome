import Foundation

enum TranscriptLoggerError: LocalizedError {
    case cannotCreateFile(String)
    var errorDescription: String? {
        switch self { case .cannotCreateFile(let p): return "Cannot create transcript at \(p)" }
    }
}

/// Writes structured markdown transcripts to the vault.
actor TranscriptLogger {
    private var fileHandle: FileHandle?
    private var currentFilePath: URL?
    private var sessionStartTime: Date?
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []
    // Retained from last session for post-session diarization and frontmatter finalization
    private var lastSessionFilePath: URL?
    private var lastSessionStartTime: Date?
    private var lastSpeakersDetected: Set<String> = []
    private var lastSessionContext: String = ""
    private var suggestedFilename: String?
    private var lastSuggestedFilename: String?

    func getLastSessionStartTime() -> Date? { lastSessionStartTime }

    func setSuggestedFilename(_ name: String?) {
        suggestedFilename = name
    }

    func startSession(sourceApp: String, vaultPath: String, sessionType: SessionType = .callCapture) throws {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.sessionContext = ""
        self.utteranceBuffer = []

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

    func endSession() {
        // Flush remaining buffer
        flushBuffer()

        // Close file handle immediately so next session can start
        try? fileHandle?.close()
        fileHandle = nil

        // Retain for post-session diarization and frontmatter finalization
        lastSessionFilePath = currentFilePath
        lastSessionStartTime = sessionStartTime
        lastSpeakersDetected = speakersDetected
        lastSessionContext = sessionContext
        lastSuggestedFilename = suggestedFilename

        // Reset state immediately so next session can start
        currentFilePath = nil
        sessionStartTime = nil
        speakersDetected = []
        sessionContext = ""
        suggestedFilename = nil

        // Frontmatter rewrite is NOT called here — caller must call
        // finalizeFrontmatter() AFTER diarization completes to avoid race.
    }

    /// Call AFTER diarization is complete. Rewrites frontmatter with correct
    /// duration, speaker count, attendees, and optionally renames the file.
    @discardableResult
    func finalizeFrontmatter() async -> URL? {
        guard let filePath = lastSessionFilePath,
              let startTime = lastSessionStartTime else { return nil }

        Self.rewriteFrontmatter(
            filePath: filePath,
            startTime: startTime,
            speakers: lastSpeakersDetected,
            context: lastSessionContext,
            suggestedFilename: lastSuggestedFilename
        )

        // Update lastSessionFilePath if the file was renamed
        if let suggested = lastSuggestedFilename, !suggested.isEmpty {
            // WhisperCal provided a filename — use it directly
            let sanitized = suggested
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let newFilename = "\(sanitized).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)
            lastSessionFilePath = newPath
        } else if !lastSessionContext.isEmpty {
            let truncated = String(lastSessionContext.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)
            lastSessionFilePath = newPath
        }

        let savedPath = lastSessionFilePath
        lastSessionStartTime = nil
        lastSpeakersDetected = []
        lastSessionContext = ""
        lastSuggestedFilename = nil
        return savedPath
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        speakers: Set<String>,
        context: String,
        suggestedFilename: String? = nil
    ) {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Calculate duration
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        // Build attendees array
        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = sortedSpeakers.isEmpty ? "[]" : "[\"\(sortedSpeakers.joined(separator: "\", \""))\"]"

        // Update frontmatter fields (regex to handle already-rewritten values)
        if let range = content.range(of: #"duration: "\d{2}:\d{2}""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        }
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        // Update header line (regex to handle already-rewritten values)
        if let range = content.range(of: #"\*\*Duration:\*\* \d{2}:\d{2} \| \*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Duration:** \(durationStr) | **Speakers:** \(speakers.count)")
        }

        // File rename: suggestedFilename takes precedence over context-based rename
        var finalPath = filePath
        if let suggested = suggestedFilename, !suggested.isEmpty {
            let sanitized = suggested
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let newFilename = "\(sanitized).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        } else if !context.isEmpty {
            let truncated = String(context.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)

        if finalPath != filePath {
            // Rename: atomically replace original, then move to new name
            _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
            try? FileManager.default.moveItem(at: filePath, to: finalPath)
        } else {
            _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        }
    }

    /// Rebuild the transcript by replacing all "Them" utterances with re-transcribed,
    /// per-speaker segments from the diarization pipeline.
    func rebuildFromDiarizedSegments(
        _ diarizedSegments: [(speaker: String, text: String, startTime: Float)],
        sessionStartTime: Date
    ) {
        guard let filePath = currentFilePath ?? lastSessionFilePath else { return }
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Find the "## Transcript" section
        guard let transcriptStart = content.range(of: "## Transcript\n") else { return }

        // Separate the file into header (everything up to and including "## Transcript\n") and body
        let header = String(content[..<transcriptStart.upperBound])

        // Collect "You" utterances from the existing transcript body
        let body = String(content[transcriptStart.upperBound...])
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        // Parse existing You utterances to preserve them
        let youPattern = #"\*\*You\*\* \((\d{2}:\d{2}:\d{2})\)\n(.*?)(?=\n\n|\z)"#
        let youRegex = try? NSRegularExpression(pattern: youPattern, options: .dotMatchesLineSeparators)
        var youUtterances: [(timestamp: Date, text: String)] = []
        if let youRegex {
            let nsBody = body as NSString
            let youMatches = youRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            for match in youMatches {
                let timeStr = nsBody.substring(with: match.range(at: 1))
                let text = nsBody.substring(with: match.range(at: 2))
                if let date = timeFmt.date(from: timeStr) {
                    // Reconstruct full date from session start + time components
                    let calendar = Calendar.current
                    let timeComps = calendar.dateComponents([.hour, .minute, .second], from: date)
                    var fullDate = calendar.dateComponents([.year, .month, .day], from: sessionStartTime)
                    fullDate.hour = timeComps.hour
                    fullDate.minute = timeComps.minute
                    fullDate.second = timeComps.second
                    if let reconstructed = calendar.date(from: fullDate) {
                        youUtterances.append((timestamp: reconstructed, text: text))
                    }
                }
            }
        }

        // Build combined timeline: diarized system segments + You utterances
        struct TimelineEntry: Comparable {
            let speaker: String
            let text: String
            let timestamp: Date
            static func < (lhs: TimelineEntry, rhs: TimelineEntry) -> Bool {
                lhs.timestamp < rhs.timestamp
            }
        }

        var timeline: [TimelineEntry] = []

        // Add diarized segments
        for seg in diarizedSegments {
            let segDate = sessionStartTime.addingTimeInterval(TimeInterval(seg.startTime))
            timeline.append(TimelineEntry(speaker: seg.speaker, text: seg.text, timestamp: segDate))
        }

        // Add You utterances
        for you in youUtterances {
            timeline.append(TimelineEntry(speaker: "You", text: you.text, timestamp: you.timestamp))
        }

        timeline.sort()

        // Rebuild transcript body
        var newBody = ""
        let allSpeakers = Set(timeline.map(\.speaker))
        for entry in timeline {
            newBody += "**\(entry.speaker)** (\(timeFmt.string(from: entry.timestamp)))\n"
            newBody += "\(entry.text)\n\n"
        }

        // Update lastSpeakersDetected for finalizeFrontmatter
        lastSpeakersDetected = allSpeakers

        // Update speaker count in header
        var updatedHeader = header
        if let range = updatedHeader.range(of: #"\*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            updatedHeader.replaceSubrange(range, with: "**Speakers:** \(allSpeakers.count)")
        }

        content = updatedHeader + newBody

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_diar_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
    }

    /// Rewrite the transcript file, replacing "Them" labels with diarized speaker IDs.
    /// Segments are (speakerId, startTimeSeconds, endTimeSeconds) from the offline diarizer.
    func rewriteWithDiarization(segments: [(speakerId: String, startTime: Float, endTime: Float)]) {
        guard let filePath = currentFilePath ?? lastSessionFilePath else { return }
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Build a map of unique diarization speaker IDs → friendly labels (Speaker 2, 3, etc.)
        let diarSpeakerMap = speakerLabels(from: segments.map(\.speakerId))

        // Parse transcript lines and re-attribute "Them" utterances based on timestamp overlap
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        // For each "**Them** (HH:mm:ss)" line, find the best matching diarization segment
        let pattern = #"\*\*Them\*\* \((\d{2}:\d{2}:\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        // Extract all utterance offsets so we can estimate end times
        guard let sessionStart = sessionStartTime ?? lastSessionStartTime else { return }
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: sessionStart)
        let sessionStartSecs = (startComponents.hour ?? 0) * 3600 + (startComponents.minute ?? 0) * 60 + (startComponents.second ?? 0)

        func offsetFor(_ timeStr: String) -> Float? {
            guard let d = timeFmt.date(from: timeStr) else { return nil }
            let c = calendar.dateComponents([.hour, .minute, .second], from: d)
            let secs = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
            return Float(secs - sessionStartSecs)
        }

        // Collect offsets for all matches
        var matchOffsets: [Float] = []
        for match in matches {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            matchOffsets.append(offsetFor(timeStr) ?? 0)
        }

        // Process in reverse so range offsets stay valid
        for (idx, match) in matches.enumerated().reversed() {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            let uttStart = matchOffsets[idx]
            // Estimate end as start of next utterance, or start + 10s
            let uttEnd = idx + 1 < matchOffsets.count ? matchOffsets[idx + 1] : uttStart + 10

            // Find dominant speaker across the utterance's time range
            var speakerDurations: [String: Float] = [:]
            for seg in segments {
                let overlapStart = max(uttStart, seg.startTime)
                let overlapEnd = min(uttEnd, seg.endTime)
                if overlapStart < overlapEnd {
                    let duration = overlapEnd - overlapStart
                    let label = diarSpeakerMap[seg.speakerId] ?? seg.speakerId
                    speakerDurations[label, default: 0] += duration
                }
            }

            var bestMatch = speakerDurations.max(by: { $0.value < $1.value })?.key

            // Fallback: closest segment if no overlap found
            if bestMatch == nil {
                var minDist: Float = .infinity
                for seg in segments {
                    let midpoint = (seg.startTime + seg.endTime) / 2
                    let dist = abs(uttStart - midpoint)
                    if dist < minDist && dist < 10 {
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

        // Replace any remaining "Them" entries that weren't matched by diarization
        // (fallback to "Speaker 2" if only one remote speaker or no segment match)
        let fallbackLabel = diarSpeakerMap.isEmpty ? "Speaker 2" : diarSpeakerMap.values.sorted().first ?? "Speaker 2"
        content = content.replacingOccurrences(of: "**Them**", with: "**\(fallbackLabel)**")

        // Update lastSpeakersDetected so finalizeFrontmatter uses diarized names
        let diarizedNames = Set(diarSpeakerMap.values)
        let hasYou = lastSpeakersDetected.contains("You")
        lastSpeakersDetected = diarizedNames
        if hasYou { lastSpeakersDetected.insert("You") }
        // Include fallback label if diarization found no speakers
        if diarizedNames.isEmpty { lastSpeakersDetected.insert(fallbackLabel) }

        // Update speaker count in header
        if let range = content.range(of: #"\*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Speakers:** \(lastSpeakersDetected.count)")
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_diar_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
    }

}
