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
        var content = try readContent(from: filePath, context: "rebuildFromDiarizedSegments")
        guard let transcriptStart = content.range(of: "## Transcript\n") else {
            // The note was edited (or replaced) out from under us — refuse to
            // rewrite rather than silently succeeding, so the caller keeps the WAV.
            throw .markdownReadFailed("rebuildFromDiarizedSegments: \(filePath.lastPathComponent) has no '## Transcript' section")
        }

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
        var content = try readContent(from: filePath, context: "rewriteWithDiarization")

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
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else {
            diagLog("[FINALIZER] setRecordingLink: couldn't read \(filePath.lastPathComponent) (non-fatal — audio and transcript both intact)")
            return
        }
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
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else {
            diagLog("[FINALIZER] setVoiceprintsLink: couldn't read \(filePath.lastPathComponent) (non-fatal — sibling sidecar remains the fallback)")
            return
        }
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

    /// Re-locate a transcript note that an external tool renamed out from under a
    /// pending job. The user's vault pipeline (WhisperCal) retitles inbox notes —
    /// field-observed 2026-07-10, where it renamed a note MID-SESSION and the
    /// finalize job then failed `markdownReadFailed`, losing the diarized rebuild.
    /// The rename preserves Tome's frontmatter, so the note is findable by its
    /// `source_file:` key, which still holds the filename Tome created (quoted or
    /// not — the external YAML round-trip strips quotes). Returns the renamed
    /// note's URL only when the original path is gone AND exactly one sibling
    /// note claims it; nil (no relocation) otherwise.
    static func relocateRenamedNote(from filePath: URL) -> URL? {
        guard !FileManager.default.fileExists(atPath: filePath.path) else { return nil }
        let originalName = filePath.lastPathComponent
        let dir = filePath.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let escaped = NSRegularExpression.escapedPattern(for: originalName)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^source_file:\s*"?"# + escaped + #""?\s*$"#) else {
            return nil
        }

        var matches: [URL] = []
        for url in siblings where url.pathExtension.lowercased() == "md" && !url.lastPathComponent.hasPrefix(".") {
            // Frontmatter sits at the top of the note — 4 KB is plenty, and keeps
            // the fallback scan cheap across a large vault folder. Lossy decoding
            // is fine: a truncated trailing multi-byte char can't affect the match.
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: 4096)) ?? nil
            try? handle.close()
            guard let data else { continue }
            let head = String(decoding: data, as: UTF8.self)
            if regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil {
                matches.append(url)
            }
        }

        switch matches.count {
        case 1:
            diagLog("[FINALIZER] relocated externally-renamed note: \(originalName) → \(matches[0].lastPathComponent)")
            return matches[0]
        case 0:
            return nil
        default:
            diagLog("[FINALIZER] relocate: \(matches.count) notes claim source_file \(originalName) — ambiguous, not relocating")
            return nil
        }
    }

    // MARK: - Provisional call → voice memo retype

    /// Re-type a provisionally-written call note as a voice memo and move it to the
    /// voice folder. Returns the snapshot re-pointed at the new path. Content rewrite
    /// is atomic-in-place FIRST; the cross-folder move is best-effort SECOND. A failed
    /// move leaves a correctly-typed memo in the meetings folder (logged via
    /// diagLogError), never a half-written file.
    ///
    /// `source_file:` never names a file the note isn't, at any point a crash could
    /// freeze: the in-place rewrite leaves it exactly as read, so a crash before
    /// the move leaves a self-consistent memo at the old path (and one between the
    /// move and the patch leaves the OLD name, which `relocateRenamedNote(from:)`
    /// still matches for a same-folder rename). Only once the note sits under a NEW
    /// basename does a second, best-effort write at the final path patch it to
    /// that basename; a failure there is logged, never thrown — the note is already
    /// a valid memo.
    ///
    /// Patches (frontmatter-scoped, tolerant of an external YAML round-trip that
    /// stripped quotes or inlined the tag list): `type: meeting` → `fleeting`,
    /// `source_app:` → `"Voice Memo"`, tags `log/meeting`/`source/meeting` →
    /// `log/voice`/`source/voice`, and the `# Call Recording — ` heading →
    /// `# Voice Memo — `. Every other byte — `duration`, `attendees`, `context`,
    /// `session_guid`, `created`, `time`, the transcript body — is left as is.
    /// Idempotent: an already memo-shaped note only moves.
    ///
    /// The filename changes only when it is still Tome's default call-label name
    /// for this session (see `shouldAdoptVoiceDefaultName`); a context-, API- or
    /// externally-renamed note keeps its name. A note an external pipeline has
    /// bound (`meeting_note:` / `pipeline_state:` in the frontmatter) is re-typed
    /// in place and neither renamed nor moved.
    static func retypeAsVoiceMemo(
        snapshot: TranscriptSessionSnapshot,
        plan: RetypePlan
    ) throws(PostProcessingError) -> TranscriptSessionSnapshot {
        try retypeAsVoiceMemo(snapshot: snapshot, plan: plan) { from, to in
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Test seam: `moveItem` stands in for `FileManager.moveItem(at:to:)` so the
    /// move-failure branches (which a real filesystem can't produce without also
    /// failing the content write) are exercisable.
    static func retypeAsVoiceMemo(
        snapshot: TranscriptSessionSnapshot,
        plan: RetypePlan,
        moveItem: (URL, URL) throws -> Void
    ) throws(PostProcessingError) -> TranscriptSessionSnapshot {
        let source = snapshot.filePath
        let sourceDir = source.deletingLastPathComponent()
        let currentName = source.lastPathComponent

        // 1. Read. Throws → the job fails; nothing on disk has been touched.
        let original = try readContent(from: source, context: "retypeAsVoiceMemo")
        let doc = RetypeDocument(original)
        if doc.frontmatter == nil {
            diagLogError("[FINALIZER] retype: \(currentName) has no frontmatter block — only the heading can be re-typed")
        }
        for note in doc.notes { diagLog("[FINALIZER] retype: \(note) in \(currentName)") }

        // 2. Plan the destination before touching anything — a voice folder that
        //    can't be created, or a name taken 100 times over, degrades to a
        //    same-folder rename or no move at all.
        let desiredName: String
        var target = source
        if doc.isExternallyLinked {
            desiredName = currentName
            diagLog("[FINALIZER] retype: note already linked by an external pipeline — re-typed in place, not moved")
        } else {
            desiredName = shouldAdoptVoiceDefaultName(snapshot: snapshot, plan: plan)
                ? voiceDefaultFilename(snapshot: snapshot, plan: plan)
                : currentName
            var voiceFolderReady = true
            do {
                try FileManager.default.createDirectory(at: plan.voiceFolder, withIntermediateDirectories: true)
            } catch {
                voiceFolderReady = false
                diagLogError("[FINALIZER] retype: move to voice folder failed (couldn't create \(plan.voiceFolder.lastPathComponent): \(error)) — memo left in place")
            }
            target = (voiceFolderReady ? retypeDestination(in: plan.voiceFolder, name: desiredName, movingFrom: source) : nil)
                ?? retypeDestination(in: sourceDir, name: desiredName, movingFrom: source)
                ?? source
        }

        // 3. Content rewrite, atomic, in place — type / source_app / tags / heading
        //    only. `source_file:` stays exactly as read: the note still has its
        //    original name here, and a crash before step 4 must leave it claiming
        //    that name. Skipped when nothing changes (an already-memo note) so
        //    mtime isn't bumped.
        let retyped = doc.render(sourceFileName: nil)
        if retyped != original {
            try atomicWrite(retyped, to: source, tmpName: ".tome_retype_tmp.md", context: "retypeAsVoiceMemo")
        }

        // 4. Move, best-effort. Content is already safe at `source`.
        var final = source
        if !isSamePath(target, source) {
            do {
                try moveItem(source, target)
                final = target
            } catch {
                diagLogError("[FINALIZER] retype: move to voice folder failed: \(currentName) → \(target.deletingLastPathComponent().lastPathComponent)/\(target.lastPathComponent): \(error) — memo left in place")
                // The note can't leave its folder; still give it the name it would have had.
                if !isSameDirectory(target.deletingLastPathComponent(), sourceDir),
                   desiredName != currentName,
                   let local = retypeDestination(in: sourceDir, name: desiredName, movingFrom: source),
                   !isSamePath(local, source) {
                    do {
                        try moveItem(source, local)
                        final = local
                    } catch {
                        diagLogError("[FINALIZER] retype: same-folder rename also failed: \(currentName) → \(local.lastPathComponent): \(error)")
                    }
                }
            }
        }

        // 5. Only now that the note actually carries a new basename, point
        //    `source_file:` at it. Same basename (never moved, moved under its
        //    own name, or an externally-renamed note keeping its name) → the
        //    original line stands; for an externally-renamed note that's the
        //    pipeline's correlation key, ours to leave. Best-effort, like
        //    `setRecordingLink`: re-read what's on disk and re-render it (the
        //    retype patches are already applied, so only that line changes).
        if final.lastPathComponent != currentName {
            patchSourceFile(at: final, previousName: currentName)
        }

        diagLog("[FINALIZER] retyped provisional call note as voice memo → \(final.lastPathComponent)")
        return snapshot.withFilePath(final)
    }

    /// Whether the note still carries Tome's own default call-label name for this
    /// session — the only name the retype may replace. Requires no API
    /// `suggestedFilename` and no session context (finalize renames from context
    /// later), and a stem equal to exactly what `TranscriptLogger.startSession`
    /// produced from the snapshotted call label, optionally with its `-N`
    /// collision suffix.
    private static func shouldAdoptVoiceDefaultName(
        snapshot: TranscriptSessionSnapshot,
        plan: RetypePlan
    ) -> Bool {
        guard snapshot.suggestedFilename == nil, snapshot.sessionContext.isEmpty else { return false }
        let path = snapshot.filePath
        guard path.pathExtension == "md" else { return false }
        let stem = path.deletingPathExtension().lastPathComponent
        let base = FilenameSanitizer.defaultTranscriptStem(
            start: snapshot.sessionStartTime,
            dateFormat: snapshot.filenameDateFormat,
            typeLabel: plan.callFilenameTypeLabel,
            fallbackLabel: "Call Recording"
        )
        if stem == base { return true }
        guard stem.hasPrefix(base + "-") else { return false }
        let suffix = stem.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func voiceDefaultFilename(snapshot: TranscriptSessionSnapshot, plan: RetypePlan) -> String {
        FilenameSanitizer.defaultTranscriptStem(
            start: snapshot.sessionStartTime,
            dateFormat: snapshot.filenameDateFormat,
            typeLabel: plan.voiceFilenameTypeLabel,
            fallbackLabel: "Voice Memo"
        ) + ".md"
    }

    /// Step 5 of the retype: rewrite `source_file:` in the note now at `url` to
    /// `url`'s basename. Never throws — the note is already a valid memo, and a
    /// stale `source_file:` (naming `previousName`) is the worst outcome.
    private static func patchSourceFile(at url: URL, previousName: String) {
        let newName = url.lastPathComponent
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            diagLogError("[FINALIZER] retype: couldn't re-read \(newName) to update source_file: — it still names \(previousName): \(error)")
            return
        }
        let doc = RetypeDocument(content)
        guard doc.sourceFileLine != nil else {
            diagLog("[FINALIZER] retype: no source_file: field to patch (renamed to \(newName))")
            return
        }
        let patched = doc.render(sourceFileName: newName)
        guard patched != content else { return }
        do {
            try atomicWrite(patched, to: url, tmpName: ".tome_retype_tmp.md", context: "retypeAsVoiceMemo(source_file)")
        } catch {
            diagLogError("[FINALIZER] retype: couldn't update source_file: in \(newName) — it still names \(previousName): \(error)")
        }
    }

    /// First free `<name>`, `<stem>-1.md`, … `<stem>-100.md` in `dir` — the same
    /// suffix scheme as `rewriteFrontmatter`. A candidate that IS `source` counts
    /// as free (the note already holds that slot). Nil if all 100 are taken.
    /// (Sibling collision loops: `rewriteFrontmatter` here and
    /// `TranscriptLogger.collisionFreeURL`, which falls back to a UUID suffix.)
    private static func retypeDestination(in dir: URL, name: String, movingFrom source: URL) -> URL? {
        let first = dir.appendingPathComponent(name)
        if isSamePath(first, source) || !FileManager.default.fileExists(atPath: first.path) { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 1...100 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            if isSamePath(candidate, source) || !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        diagLog("[FINALIZER] retype: gave up after 100 collision attempts for \(name) in \(dir.lastPathComponent)")
        return nil
    }

    private static func isSamePath(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent == b.lastPathComponent
            && isSameDirectory(a.deletingLastPathComponent(), b.deletingLastPathComponent())
    }

    /// Compare directories after resolving symlinks (`/var` vs `/private/var`,
    /// a vault reached through a link), so "voice folder == meetings folder" is
    /// recognized however the two paths were spelled.
    private static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The note split into lines (losslessly — `render` rejoins on `\n`) with the
    /// retype's patches pre-applied, except `source_file:`, whose value depends on
    /// where the note ends up and is supplied at render time.
    private struct RetypeDocument {
        private var lines: [String]
        /// Line indices of the frontmatter body (between the `---` fences).
        let frontmatter: Range<Int>?
        let sourceFileLine: Int?
        let isExternallyLinked: Bool
        private(set) var notes: [String] = []

        init(_ content: String) {
            var lines = content.components(separatedBy: "\n")
            var frontmatter: Range<Int>?
            if lines.first.map(Self.trimmed) == "---",
               let close = lines.indices.dropFirst().first(where: { Self.trimmed(lines[$0]) == "---" }) {
                frontmatter = 1..<close
            }
            self.frontmatter = frontmatter

            var sourceFileLine: Int?
            var linked = false
            var notes: [String] = []
            var sawType = false, sawSourceApp = false
            if let fm = frontmatter {
                var inTagList = false
                for i in fm {
                    let line = lines[i]
                    if let (key, value) = Self.topLevelKey(line) {
                        inTagList = false
                        switch key {
                        case "type":
                            sawType = true
                            switch Self.unquoted(value) {
                            case "meeting": lines[i] = "type: fleeting"
                            case "fleeting": break
                            default: notes.append("type: is '\(Self.unquoted(value))', not meeting — left as is")
                            }
                        case "source_app":
                            sawSourceApp = true
                            lines[i] = "source_app: \"Voice Memo\""
                        case "source_file":
                            sourceFileLine = sourceFileLine ?? i
                        case "tags":
                            let v = Self.trimmed(value)
                            if v.isEmpty {
                                inTagList = true
                            } else if v.hasPrefix("["), v.hasSuffix("]") {
                                lines[i] = Self.patchingInlineTags(line)
                            }
                        case "meeting_note", "pipeline_state":
                            linked = true
                        default:
                            break
                        }
                    } else if inTagList {
                        lines[i] = Self.patchingListItem(line)
                    }
                }
                if !sawType { notes.append("no type: field to patch") }
                if !sawSourceApp { notes.append("no source_app: field to patch") }
            }

            // Heading: first `# Call Recording — ` line after the frontmatter and
            // before the transcript — utterance text is never inspected.
            let bodyStart = frontmatter.map { $0.upperBound + 1 } ?? 0
            var headingPatched = false
            var i = bodyStart
            while i < lines.count, lines[i] != "## Transcript" {
                if lines[i].hasPrefix("# Call Recording — ") {
                    lines[i] = "# Voice Memo — " + lines[i].dropFirst("# Call Recording — ".count)
                    headingPatched = true
                    break
                }
                if lines[i].hasPrefix("# Voice Memo — ") { headingPatched = true; break }
                i += 1
            }
            if !headingPatched { notes.append("no '# Call Recording — ' heading to patch") }

            self.lines = lines
            self.sourceFileLine = sourceFileLine
            self.isExternallyLinked = linked
            self.notes = notes
        }

        /// Full note text. `sourceFileName` nil = the `source_file:` line exactly as read.
        func render(sourceFileName: String?) -> String {
            var out = lines
            if let sourceFileName, let idx = sourceFileLine {
                out[idx] = "source_file: \"\(Self.yamlEscaped(sourceFileName))\""
            }
            return out.joined(separator: "\n")
        }

        /// `key: value` at column 0 (a top-level mapping key). Indented lines,
        /// list items and comments are not keys.
        private static func topLevelKey(_ line: String) -> (String, Substring)? {
            guard let first = line.first, !first.isWhitespace, first != "-", first != "#",
                  let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon]
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
            return (String(key), line[line.index(after: colon)...])
        }

        /// `  - <tag>` item under a block-style `tags:` key.
        private static func patchingListItem(_ line: String) -> String {
            guard let dash = line.firstIndex(where: { !$0.isWhitespace }), line[dash] == "-" else { return line }
            let afterDash = line.index(after: dash)
            guard afterDash < line.endIndex, line[afterDash].isWhitespace else { return line }
            let prefixEnd = line[afterDash...].firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
            return String(line[..<prefixEnd]) + swappingTag(line[prefixEnd...])
        }

        /// `tags: [a, b, …]` — swap whole elements only.
        private static func patchingInlineTags(_ line: String) -> String {
            guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return line }
            let inner = line[line.index(after: open)..<close]
            let items = inner.components(separatedBy: ",").map { swappingTag(Substring($0)) }
            return String(line[...open]) + items.joined(separator: ",") + String(line[close...])
        }

        /// Swap one tag token, preserving its surrounding whitespace and quotes.
        private static func swappingTag(_ raw: Substring) -> String {
            guard let lo = raw.firstIndex(where: { !$0.isWhitespace }),
                  let hi = raw.lastIndex(where: { !$0.isWhitespace }) else { return String(raw) }
            let token = raw[lo...hi]
            var quote = ""
            var core = token
            if token.count >= 2, let q = token.first, q == "\"" || q == "'", token.last == q {
                quote = String(q)
                core = token.dropFirst().dropLast()
            }
            let swapped: String
            switch core {
            case "log/meeting": swapped = "log/voice"
            case "source/meeting": swapped = "source/voice"
            default: return String(raw)
            }
            return String(raw[..<lo]) + quote + swapped + quote + String(raw[raw.index(after: hi)...])
        }

        private static func unquoted(_ value: Substring) -> String {
            var v = trimmed(value)
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        private static func trimmed<S: StringProtocol>(_ s: S) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func yamlEscaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
        var content = try readContent(from: filePath, context: "rewriteFrontmatter")

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
        } else {
            diagLog("[FINALIZER] rewriteFrontmatter: no inline attendees: array to patch in \(filePath.lastPathComponent) (externally restructured?)")
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

    /// Read the transcript for a rewrite step. Throws instead of letting callers
    /// `try?`-swallow: an unreadable note (vault unmounted, iCloud-evicted,
    /// permission change, user rename) must fail the step loudly — the caller's
    /// contract is that source WAVs are only deleted after a *verified* rewrite.
    private static func readContent(
        from filePath: URL,
        context: String
    ) throws(PostProcessingError) -> String {
        do {
            return try String(contentsOf: filePath, encoding: .utf8)
        } catch {
            diagLogError("[FINALIZER] \(context): transcript unreadable at \(filePath.path): \(error)")
            throw .markdownReadFailed("\(context): couldn't read \(filePath.lastPathComponent) — \(error.localizedDescription)")
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
        // Uniquify the tmp name per call: finalization of session N can overlap the
        // live logger (and other finalize steps) writing into the same vault folder,
        // and a shared tmp name lets one session's content be atomically installed
        // over another session's note.
        let uniqueTmpName = "\(tmpName.dropLast(3))-\(UUID().uuidString.prefix(8)).md"
        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(uniqueTmpName)
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            diagLogError("[FINALIZER] \(context): tmp write failed at \(tmpPath.path): \(error)")
            throw .markdownWriteFailed("\(context): tmp write failed — \(error.localizedDescription)")
        }
        do {
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            diagLogError("[FINALIZER] \(context): replaceItemAt failed for \(filePath.path): \(error)")
            throw .markdownWriteFailed("\(context): replaceItemAt failed — \(error.localizedDescription)")
        }
    }
}
