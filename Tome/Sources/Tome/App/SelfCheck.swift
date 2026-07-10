@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Preflight health check behind `tome --selfcheck` — runnable before an
/// important meeting, and by CI as a smoke test of the built binary.
///
/// Structural checks (can Tome persist a recording at all?) gate the exit
/// code. Environment checks (TCC permissions, API port file) are informational
/// only: a headless CI runner has neither mic nor screen access, and that must
/// not fail the smoke test.
struct SelfCheck {
    struct Item {
        let name: String
        let ok: Bool
        let detail: String
        /// Critical items decide `ok`; informational items only appear in the report.
        let critical: Bool
    }

    let items: [Item]

    var ok: Bool { items.allSatisfy { !$0.critical || $0.ok } }

    var report: String {
        var lines = ["Tome self-check"]
        for item in items {
            let tag = item.ok ? "PASS" : (item.critical ? "FAIL" : "WARN")
            lines.append("  [\(tag)] \(item.name): \(item.detail)")
        }
        lines.append(ok ? "RESULT: OK" : "RESULT: FAIL")
        return lines.joined(separator: "\n")
    }

    /// - Parameter sessionsDirectory: override for tests; production resolves
    ///   the app's real sessions directory.
    static func run(sessionsDirectory: URL? = nil) -> SelfCheck {
        var items: [Item] = []
        let fm = FileManager.default

        // 1. Sessions directory writable — where every crash-safe artifact lives.
        let dir = sessionsDirectory ?? (try? SystemAudioCapture.sessionsDirectory())
        var writableDir: URL?
        if let dir {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".selfcheck-\(UUID().uuidString)")
                try Data("ok".utf8).write(to: probe)
                try fm.removeItem(at: probe)
                writableDir = dir
                items.append(Item(name: "sessions directory", ok: true, detail: dir.path, critical: true))
            } catch {
                items.append(Item(name: "sessions directory", ok: false,
                                  detail: "\(dir.path): \(error.localizedDescription)", critical: true))
            }
        } else {
            items.append(Item(name: "sessions directory", ok: false,
                              detail: "cannot resolve Application Support", critical: true))
        }

        // 2. WAV writer round trip — create, write a beat of audio, reopen, read.
        do {
            let target = writableDir ?? fm.temporaryDirectory
            let wavURL = target.appendingPathComponent(".selfcheck-\(UUID().uuidString).wav")
            defer { try? fm.removeItem(at: wavURL) }
            let writer = try WAVStreamWriter(url: wavURL, sampleRate: 48_000)
            if let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
               let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_800) {
                buf.frameLength = 4_800
                try writer.write(buf)
            }
            writer.close()
            let file = try AVAudioFile(forReading: wavURL)
            let frames = file.length
            items.append(Item(name: "WAV writer", ok: frames == 4_800,
                              detail: "wrote+read \(frames) frames", critical: true))
        } catch {
            items.append(Item(name: "WAV writer", ok: false,
                              detail: error.localizedDescription, critical: true))
        }

        // 3. Microphone permission (informational — TCC state, not app health).
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micDetail: String = switch micStatus {
        case .authorized: "granted"
        case .denied: "denied (enable in System Settings > Privacy & Security > Microphone)"
        case .restricted: "restricted"
        case .notDetermined: "not requested yet"
        @unknown default: "unknown"
        }
        items.append(Item(name: "microphone permission", ok: micStatus == .authorized,
                          detail: micDetail, critical: false))

        // 4. Screen recording permission (informational).
        let screen = CGPreflightScreenCaptureAccess()
        items.append(Item(name: "screen recording permission", ok: screen,
                          detail: screen ? "granted" : "not granted (system audio capture unavailable)",
                          critical: false))

        // 5. API port file (informational — only meaningful while the app runs).
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let portFile = appSupport.appendingPathComponent("Tome/api-port")
            let exists = fm.fileExists(atPath: portFile.path)
            items.append(Item(name: "API port file", ok: exists,
                              detail: exists ? portFile.path : "absent (normal when Tome isn't running)",
                              critical: false))
        }

        return SelfCheck(items: items)
    }
}
