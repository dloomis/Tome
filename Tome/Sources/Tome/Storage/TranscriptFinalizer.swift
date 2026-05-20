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
    ) throws(PostProcessingError) {
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

        try atomicWrite(content, to: filePath, context: "rebuildFromDiarizedSegments")
    }

    /// Rewrite the transcript file, replacing "Them" labels with diarized speaker IDs.
    /// Used as a fallback when re-transcription fails; preserves existing transcript
    /// structure and just re-attributes "Them" lines to specific speakers.
    static func rewriteWithDiarization(
        snapshot: inout TranscriptSessionSnapshot,
        segments: [DiarizedSegment]
    ) throws(PostProcessingError) {
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

        try atomicWrite(content, to: filePath, context: "rewriteWithDiarization")
    }

    /// Rewrite the YAML frontmatter with final duration, speaker count, and attendees.
    /// Renames the file if a suggested filename or context is present.
    /// Returns the final (possibly renamed) path. Throws if the frontmatter content
    /// write fails — the rename step is best-effort and only diagLog'd on failure
    /// because content has already landed at the original path.
    @discardableResult
    static func finalizeFrontmatter(
        snapshot: TranscriptSessionSnapshot
    ) throws(PostProcessingError) -> URL {
        try rewriteFrontmatter(
            filePath: snapshot.filePath,
            startTime: snapshot.sessionStartTime,
            speakers: snapshot.speakersDetected,
            context: snapshot.sessionContext,
            suggestedFilename: snapshot.suggestedFilename,
            filenameDateFormat: snapshot.filenameDateFormat
        )
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        speakers: Set<String>,
        context: String,
        suggestedFilename: String? = nil,
        filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss"
    ) throws(PostProcessingError) -> URL {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return filePath }

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
        if let suggested = suggestedFilename,
           let sanitized = FilenameSanitizer.sanitize(suggested) {
            let newFilename = "\(sanitized).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        } else if let truncated = FilenameSanitizer.sanitize(String(context.prefix(50))),
                  !truncated.isEmpty {
            let datePrefix = FilenameSanitizer.formattedDate(startTime, format: filenameDateFormat)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: #"source_file: ".*""#, options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            }

            finalPath = newPath
        }

        try atomicWrite(content, to: filePath, tmpName: ".tome_tmp.md", context: "rewriteFrontmatter")

        // Best-effort rename — content has already landed at filePath atomically, so a
        // rename failure does not lose data. Log and continue rather than throw.
        guard finalPath != filePath else { return filePath }

        // Resolve collisions by appending -1, -2, … so we never clobber an existing file.
        var attempt = finalPath
        var suffix = 1
        while FileManager.default.fileExists(atPath: attempt.path) {
            let stem = finalPath.deletingPathExtension().lastPathComponent
            let ext = finalPath.pathExtension
            attempt = finalPath.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(suffix).\(ext)")
            suffix += 1
            if suffix > 100 {
                diagLog("[FINALIZER] gave up after 100 collision attempts for \(finalPath.lastPathComponent)")
                return filePath
            }
        }

        do {
            try FileManager.default.moveItem(at: filePath, to: attempt)
            return attempt
        } catch {
            diagLog("[FINALIZER] rename failed: \(filePath.lastPathComponent) → \(attempt.lastPathComponent): \(error)")
            return filePath
        }
    }

    /// Write `content` to `filePath` via a temp-file + atomic-replace dance. The
    /// `try?` swallowing of these errors was the root cause of the silent
    /// diarization data loss on iCloud-backed paths — surface them as throws now.
    private static func atomicWrite(
        _ content: String,
        to filePath: URL,
        tmpName: String = ".tome_diar_tmp.md",
        context: String
    ) throws(PostProcessingError) {
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(tmpName)
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            diagLog("[FINALIZER] \(context): tmp write failed at \(tmpPath.path): \(error)")
            throw .markdownWriteFailed("\(context): tmp write failed — \(error.localizedDescription)")
        }
        do {
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            diagLog("[FINALIZER] \(context): replaceItemAt failed for \(filePath.path): \(error)")
            throw .markdownWriteFailed("\(context): replaceItemAt failed — \(error.localizedDescription)")
        }
    }
}
