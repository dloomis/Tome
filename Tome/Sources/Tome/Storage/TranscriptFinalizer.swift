import Foundation

/// Stateless markdown post-processing. Operates on an immutable `TranscriptSessionSnapshot`
/// so calls from concurrent `PostProcessingJob`s never race on shared state. Each function
/// can mutate the snapshot's `speakersDetected` via `inout` to reflect diarization results
/// that `finalizeFrontmatter` then uses.
enum TranscriptFinalizer {

    /// Rebuild the transcript by replacing all "Them" utterances with re-transcribed,
    /// per-speaker segments from the diarization pipeline. Preserves "You" utterances
    /// and interleaves them with diarized segments on the timeline. Updates
    /// `snapshot.speakersDetected` to the post-diarization speaker set.
    static func rebuildFromDiarizedSegments(
        snapshot: inout TranscriptSessionSnapshot,
        diarizedSegments: [ReTranscribedSegment]
    ) {
        let filePath = snapshot.filePath
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }
        guard let transcriptStart = content.range(of: "## Transcript\n") else { return }

        let header = String(content[..<transcriptStart.upperBound])
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
                    let calendar = Calendar.current
                    let timeComps = calendar.dateComponents([.hour, .minute, .second], from: date)
                    var fullDate = calendar.dateComponents([.year, .month, .day], from: snapshot.sessionStartTime)
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
        for seg in diarizedSegments {
            let segDate = snapshot.sessionStartTime.addingTimeInterval(TimeInterval(seg.startTime))
            timeline.append(TimelineEntry(speaker: seg.speaker, text: seg.text, timestamp: segDate))
        }
        for you in youUtterances {
            timeline.append(TimelineEntry(speaker: "You", text: you.text, timestamp: you.timestamp))
        }
        timeline.sort()

        // If the rebuilt timeline is empty, preserve the existing transcript
        guard !timeline.isEmpty else { return }

        var newBody = ""
        let allSpeakers = Set(timeline.map(\.speaker))
        for entry in timeline {
            newBody += "**\(entry.speaker)** (\(timeFmt.string(from: entry.timestamp)))\n"
            newBody += "\(entry.text)\n\n"
        }

        snapshot.speakersDetected = allSpeakers

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
    /// Used as a fallback when re-transcription fails; preserves existing transcript
    /// structure and just re-attributes "Them" lines to specific speakers.
    static func rewriteWithDiarization(
        snapshot: inout TranscriptSessionSnapshot,
        segments: [DiarizedSegment]
    ) {
        let filePath = snapshot.filePath
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Build a map of unique diarization speaker IDs → friendly labels
        let diarSpeakerMap = speakerLabels(from: segments.map(\.speakerId))

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        let pattern = #"\*\*Them\*\* \((\d{2}:\d{2}:\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: snapshot.sessionStartTime)
        let sessionStartSecs = (startComponents.hour ?? 0) * 3600 + (startComponents.minute ?? 0) * 60 + (startComponents.second ?? 0)

        func offsetFor(_ timeStr: String) -> Float? {
            guard let d = timeFmt.date(from: timeStr) else { return nil }
            let c = calendar.dateComponents([.hour, .minute, .second], from: d)
            let secs = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
            return Float(secs - sessionStartSecs)
        }

        var matchOffsets: [Float] = []
        for match in matches {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            matchOffsets.append(offsetFor(timeStr) ?? 0)
        }

        // Process in reverse so range offsets stay valid
        for (idx, match) in matches.enumerated().reversed() {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            let uttStart = matchOffsets[idx]
            let uttEnd = idx + 1 < matchOffsets.count ? matchOffsets[idx + 1] : uttStart + 10

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
        let fallbackLabel = diarSpeakerMap.isEmpty ? "Speaker 2" : diarSpeakerMap.values.sorted().first ?? "Speaker 2"
        content = content.replacingOccurrences(of: "**Them**", with: "**\(fallbackLabel)**")

        // Update snapshot's speaker set with diarized names (+ You if present)
        let diarizedNames = Set(diarSpeakerMap.values)
        let hasYou = snapshot.speakersDetected.contains("You")
        var updatedSpeakers = diarizedNames
        if hasYou { updatedSpeakers.insert("You") }
        if diarizedNames.isEmpty { updatedSpeakers.insert(fallbackLabel) }
        snapshot.speakersDetected = updatedSpeakers

        // Update speaker count in header
        if let range = content.range(of: #"\*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Speakers:** \(updatedSpeakers.count)")
        }

        // Atomic write
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(".tome_diar_tmp.md")
        try? content.write(to: tmpPath, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
    }

    /// Rewrite the YAML frontmatter with final duration, speaker count, and attendees.
    /// Renames the file if a suggested filename or context is present.
    /// Returns the final (possibly renamed) path.
    @discardableResult
    static func finalizeFrontmatter(
        snapshot: TranscriptSessionSnapshot
    ) -> URL? {
        rewriteFrontmatter(
            filePath: snapshot.filePath,
            startTime: snapshot.sessionStartTime,
            speakers: snapshot.speakersDetected,
            context: snapshot.sessionContext,
            suggestedFilename: snapshot.suggestedFilename
        )

        if let suggested = snapshot.suggestedFilename, !suggested.isEmpty {
            let sanitized = suggested
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let newFilename = "\(sanitized).md"
            return snapshot.filePath.deletingLastPathComponent().appendingPathComponent(newFilename)
        } else if !snapshot.sessionContext.isEmpty {
            let truncated = String(snapshot.sessionContext.prefix(50))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: snapshot.sessionStartTime)
            let newFilename = "\(datePrefix) \(truncated).md"
            return snapshot.filePath.deletingLastPathComponent().appendingPathComponent(newFilename)
        }
        return snapshot.filePath
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        speakers: Set<String>,
        context: String,
        suggestedFilename: String? = nil
    ) {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = sortedSpeakers.isEmpty ? "[]" : "[\"\(sortedSpeakers.joined(separator: "\", \""))\"]"

        if let range = content.range(of: #"duration: "\d{2}:\d{2}""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        }
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

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
            _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
            try? FileManager.default.moveItem(at: filePath, to: finalPath)
        } else {
            _ = try? FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        }
    }
}
