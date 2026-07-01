import Foundation

/// Stateless markdown post-processing. Operates on an immutable `TranscriptSessionSnapshot`
/// so calls from concurrent `PostProcessingJob`s never race on shared state. Each function
/// can mutate the snapshot's `speakersDetected` via `inout` to reflect diarization results
/// that `finalizeFrontmatter` then uses.
enum TranscriptFinalizer {

    /// Rebuild the transcript from re-transcribed, per-speaker diarization segments.
    /// When `preserveYou` is true (call capture), the live "You" mic utterances are parsed
    /// out and interleaved with the diarized "them" segments on the timeline — only "Them"
    /// is replaced. When false (mic-only in-person sessions, where the mic *is* the diarized
    /// stream), the body is replaced wholesale by the diarized segments; preserving "You"
    /// would duplicate every word. Updates `snapshot.speakersDetected` to the
    /// post-diarization speaker set.
    static func rebuildFromDiarizedSegments(
        snapshot: inout TranscriptSessionSnapshot,
        diarizedSegments: [ReTranscribedSegment],
        preserveYou: Bool = true
    ) throws(PostProcessingError) {
        let filePath = snapshot.filePath
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }
        guard let transcriptStart = content.range(of: "## Transcript\n") else { return }

        let header = String(content[..<transcriptStart.upperBound])
        let body = String(content[transcriptStart.upperBound...])

        // Parse existing You utterances to preserve them. The marker is the decimal-second
        // offset from session start that the live logger wrote.
        let youPattern = #"\*\*You\*\* \(([\d.]+)\)\n(.*?)(?=\n\n|\z)"#
        let youRegex = try? NSRegularExpression(pattern: youPattern, options: .dotMatchesLineSeparators)
        var youUtterances: [(offset: Double, text: String)] = []
        if preserveYou, let youRegex {
            let nsBody = body as NSString
            let youMatches = youRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            for match in youMatches {
                let offsetStr = nsBody.substring(with: match.range(at: 1))
                let text = nsBody.substring(with: match.range(at: 2))
                if let offset = Double(offsetStr) {
                    youUtterances.append((offset: offset, text: text))
                }
            }
        }

        // Build combined timeline (offsets in seconds from session start): diarized
        // system segments + You utterances. Diarized `startTime` is already an offset.
        struct TimelineEntry: Comparable {
            let speaker: String
            let text: String
            let offset: Double
            static func < (lhs: TimelineEntry, rhs: TimelineEntry) -> Bool {
                lhs.offset < rhs.offset
            }
        }

        var timeline: [TimelineEntry] = []
        for seg in diarizedSegments {
            timeline.append(TimelineEntry(speaker: seg.speaker, text: seg.text, offset: Double(seg.startTime)))
        }
        for you in youUtterances {
            timeline.append(TimelineEntry(speaker: "You", text: you.text, offset: you.offset))
        }
        timeline.sort()

        // If the rebuilt timeline is empty, preserve the existing transcript
        guard !timeline.isEmpty else { return }

        var newBody = ""
        let allSpeakers = Set(timeline.map(\.speaker))
        for entry in timeline {
            newBody += "**\(entry.speaker)** (\(formatTimeOffset(entry.offset)))\n"
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

        // Each "Them" marker is already the decimal-second offset from session start.
        let pattern = #"\*\*Them\*\* \(([\d.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        var matchOffsets: [Float] = []
        for match in matches {
            let timeStr = nsContent.substring(with: match.range(at: 1))
            matchOffsets.append(Float(timeStr) ?? 0)
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
            endTime: snapshot.sessionEndTime,
            speakers: snapshot.speakersDetected,
            context: snapshot.sessionContext,
            suggestedFilename: snapshot.suggestedFilename,
            filenameDateFormat: snapshot.filenameDateFormat
        )
    }

    /// Add (or update) a `recording:` frontmatter property linking the transcript to
    /// its retained audio file, using Obsidian wikilink syntax. The value is quoted so
    /// the `[[…]]` parses as a YAML scalar (Obsidian renders quoted wikilinks in a
    /// property as a clickable link), and the `.m4a` extension is kept because Obsidian
    /// wikilinks to non-markdown files require it. Best-effort — a failure here leaves
    /// both the saved transcript and the exported audio intact.
    static func setRecordingLink(filePath: URL, audioFilename: String) {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }
        let line = "recording: \"[[\(audioFilename)]]\""

        if let range = content.range(of: yamlField("recording"), options: .regularExpression) {
            content.replaceSubrange(range, with: line)
        } else if let range = content.range(of: yamlField("source_file"), options: .regularExpression) {
            // Land the link right under source_file, inside the existing frontmatter.
            content.insert(contentsOf: "\n" + line, at: range.upperBound)
        } else {
            diagLog("[FINALIZER] setRecordingLink: no recording:/source_file: anchor in \(filePath.lastPathComponent) — link not written")
            return
        }

        do {
            try atomicWrite(content, to: filePath, tmpName: ".tome_rec_tmp.md", context: "setRecordingLink")
        } catch {
            diagLog("[FINALIZER] setRecordingLink write failed (non-fatal): \(error)")
        }
    }

    /// Add (or update) a `voiceprints:` frontmatter property pointing at the speaker
    /// voiceprint sidecar (a plain JSON filename, not a wikilink — it's not an Obsidian
    /// note), so the association survives a later transcript rename. Best-effort: a
    /// failure just leaves the sibling `.voiceprints.json` as the fallback resolution.
    static func setVoiceprintsLink(filePath: URL, sidecarFilename: String) {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }
        let line = "voiceprints: \"\(sidecarFilename)\""

        if let range = content.range(of: yamlField("voiceprints"), options: .regularExpression) {
            content.replaceSubrange(range, with: line)
        } else if let range = content.range(of: yamlField("source_file"), options: .regularExpression) {
            content.insert(contentsOf: "\n" + line, at: range.upperBound)
        } else {
            diagLog("[FINALIZER] setVoiceprintsLink: no voiceprints:/source_file: anchor in \(filePath.lastPathComponent) — link not written")
            return
        }

        do {
            try atomicWrite(content, to: filePath, tmpName: ".tome_vp_tmp.md", context: "setVoiceprintsLink")
        } catch {
            diagLog("[FINALIZER] setVoiceprintsLink write failed (non-fatal): \(error)")
        }
    }

    /// Matches a single-line YAML frontmatter scalar field by key, regardless of
    /// whether the value is quoted. External tools (e.g. WhisperCal) round-trip Tome's
    /// frontmatter through a real YAML serializer, which drops the quotes Tome writes
    /// around values that don't strictly need them (`duration: "00:00"` becomes
    /// `duration: 00:00`) — matching broadly here means our patches keep landing even
    /// after that round-trip, instead of silently no-op'ing against a pattern that
    /// required quotes that are no longer there.
    private static func yamlField(_ key: String) -> String {
        "\(key): .*"
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        endTime: Date,
        speakers: Set<String>,
        context: String,
        suggestedFilename: String? = nil,
        filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss"
    ) throws(PostProcessingError) -> URL {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return filePath }

        // Measured at stop time (see `TranscriptSessionSnapshot.sessionEndTime`), not
        // `Date()` here — finalization runs in the background long after the user stopped.
        let elapsed = endTime.timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = sortedSpeakers.isEmpty ? "[]" : "[\"\(sortedSpeakers.joined(separator: "\", \""))\"]"

        if let range = content.range(of: yamlField("duration"), options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        } else {
            diagLog("[FINALIZER] rewriteFrontmatter: no duration: field to patch in \(filePath.lastPathComponent)")
        }
        // attendees: intentionally left unmatched once external tooling (WhisperCal) has
        // restructured it into a multi-line form — this inline-array pattern only matches
        // Tome's own single-line `attendees: [...]`, by design.
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        if let range = content.range(of: #"\*\*Duration:\*\* \d{2}:\d{2} \| \*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Duration:** \(durationStr) | **Speakers:** \(speakers.count)")
        } else {
            diagLog("[FINALIZER] rewriteFrontmatter: no body Duration header to patch in \(filePath.lastPathComponent)")
        }

        // File rename: suggestedFilename takes precedence over context-based rename
        var finalPath = filePath
        if let suggested = suggestedFilename,
           let sanitized = FilenameSanitizer.sanitize(suggested) {
            let newFilename = "\(sanitized).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: yamlField("source_file"), options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            } else {
                diagLog("[FINALIZER] rewriteFrontmatter: no source_file: field to patch (rename to \(newFilename))")
            }

            finalPath = newPath
        } else if let truncated = FilenameSanitizer.sanitize(String(context.prefix(50))),
                  !truncated.isEmpty {
            let datePrefix = FilenameSanitizer.formattedDate(startTime, format: filenameDateFormat)
            let newFilename = "\(datePrefix) \(truncated).md"
            let newPath = filePath.deletingLastPathComponent().appendingPathComponent(newFilename)

            if let range = content.range(of: yamlField("source_file"), options: .regularExpression) {
                content.replaceSubrange(range, with: "source_file: \"\(newFilename)\"")
            } else {
                diagLog("[FINALIZER] rewriteFrontmatter: no source_file: field to patch (rename to \(newFilename))")
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
