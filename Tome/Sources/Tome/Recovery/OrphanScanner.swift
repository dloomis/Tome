import Foundation

/// Finds WAV files left in `~/Library/Application Support/Tome/sessions/` from
/// crashed or force-quit recordings. Any WAV in that directory is by
/// construction an orphan: the success path of `PostProcessingJob` always
/// deletes the WAV + sidecar on completion, so anything still on disk failed
/// to finalize.
///
/// Runs once on app launch (see ContentView). Pairs each WAV with its sidecar
/// (which carries `transcriptPath`, `sessionId`, `startedAt`) so we can offer
/// the user a one-click recover. WAVs without a sidecar (from before the
/// sidecar landed) can still be recovered through the manual `Cmd+Opt+R` flow.
enum OrphanScanner {

    struct Orphan: Sendable {
        let wavURL: URL
        let sidecar: SessionSidecar?
        let wavInfo: Recovery.WAVInfo

        /// Human-readable one-liner used in launch alerts.
        /// e.g. "2026-05-20 14:04 · KSP Tag-up · 27:40 · 303 MB"
        var summaryLine: String {
            let when: String
            if let started = sidecar?.startedAt {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                when = fmt.string(from: started)
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                when = fmt.string(from: wavInfo.modifiedAt)
            }
            let dur = Int(wavInfo.durationSeconds)
            let durStr = String(format: "%d:%02d", dur / 60, dur % 60)
            let mb = Double(wavInfo.sizeBytes) / 1_048_576
            let stem: String
            if let path = sidecar?.transcriptPath {
                stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            } else {
                stem = wavURL.deletingPathExtension().lastPathComponent
            }
            return "\(when) · \(stem) · \(durStr) · \(String(format: "%.0f", mb)) MB"
        }
    }

    /// Enumerate orphans. Sorted oldest-first so the user works through them in
    /// chronological order (matches the order recordings were attempted).
    /// - Parameter directory: override for tests; production scans the app's
    ///   sessions directory.
    static func findOrphans(in directory: URL? = nil) -> [Orphan] {
        guard let dir = directory ?? (try? SystemAudioCapture.sessionsDirectory()) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        // `.mic.wav` files are usually mic-track companions of a `<sid>.wav` (call
        // captures) — hidden so a session is listed once. But for a mic-only session
        // (voice memo / in-person meeting) the mic WAV is the session's ONLY audio:
        // when no sibling `<sid>.wav` exists, it surfaces as the primary. Rotated
        // mic segments (`<sid>.pre-<ts>.mic.wav`) stay hidden — their session is
        // already represented by its current-generation files.
        let wavURLs = urls.filter { url in
            guard url.pathExtension.lowercased() == "wav" else { return false }
            let name = url.lastPathComponent
            guard name.hasSuffix(".mic.wav") else { return true }
            let base = String(name.dropLast(".mic.wav".count))
            if base.contains(".pre-") { return false }
            let sibling = url.deletingLastPathComponent().appendingPathComponent("\(base).wav")
            return !FileManager.default.fileExists(atPath: sibling.path)
        }
        var orphans: [Orphan] = []
        for wavURL in wavURLs {
            // Skip empty / placeholder WAVs (header-only files with no data).
            // ~4 KB is a reasonable floor: under 1 second of float32 mono 48 kHz.
            let attrs = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size < 4096 { continue }

            guard let info = try? Recovery.inspectWAV(wavURL) else { continue }
            if info.durationSeconds < 1.0 { continue }

            let sidecarURL = SessionSidecar.sidecarURL(forWAV: wavURL)
            let sidecar = try? SessionSidecar.read(from: sidecarURL)
            orphans.append(Orphan(wavURL: wavURL, sidecar: sidecar, wavInfo: info))
        }
        return orphans.sorted { $0.wavInfo.modifiedAt < $1.wavInfo.modifiedAt }
    }

    /// Delete the WAV and its sidecar. Caller is responsible for confirming with
    /// the user before invoking — there's no undo.
    static func discard(_ orphan: Orphan) {
        try? FileManager.default.removeItem(at: orphan.wavURL)
        SessionSidecar.deleteIfExists(forWAV: orphan.wavURL)
        try? FileManager.default.removeItem(at: SystemAudioCapture.micBufferURL(forSystemWAV: orphan.wavURL))
    }
}
