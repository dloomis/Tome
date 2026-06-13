// Cross-meeting tag audit + voiceprint backfill (diagnostic/CLI, not part of the app).
// Diarizes each meeting's mono-mix recording, maps clusters to the transcript's confirmed
// names (applying nickname aliases), audits labels via acoustic nearest-neighbour across
// meetings, and — with --enroll — writes per-person voiceprint libraries in the same
// schema as WhisperCal's live enroller, excluding instances the audit flags as mislabels.
//
//   swift run VoiceprintAudit [--enroll <Caches/Voiceprints folder>] "<m4a>" ["<m4a>" ...]
import Foundation
import SpeakerKit
import WhisperKit

// MARK: helpers
func l2(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }
func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    let n = l2(a) * l2(b)
    return n > 0 ? dot / n : -1
}
func meanNorm(_ vs: [[Float]]) -> [Float] {
    guard let first = vs.first else { return [] }
    var acc = [Float](repeating: 0, count: first.count)
    for v in vs where v.count == acc.count { for i in v.indices { acc[i] += v[i] } }
    let n = l2(acc); return n > 0 ? acc.map { $0 / n } : acc
}
func isStub(_ name: String) -> Bool {
    name.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func f3(_ x: Float) -> String { String(format: "%.3f", x) }
func sanitizeFile(_ name: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#[]")
    let s = name.components(separatedBy: illegal).joined().trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? "untitled" : s
}

// Nickname canonicalization (preferred form). Merges name variants before audit + enroll
// so one person doesn't split across two libraries.
let ALIASES: [String: String] = [
    "Steven Martin": "Steve Martin",
    "Joseph Jackson": "Joe Jackson",
    "Theodore Faber": "Ted Faber",
]
func canon(_ n: String) -> String { ALIASES[n] ?? n }

func parseTranscript(_ path: String) -> [(Double, String)] {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return [] }
    let re = try! NSRegularExpression(pattern: #"^\*\*(.+?)\*\*\s*\(([0-9]+\.[0-9]+)\)"#, options: [.anchorsMatchLines])
    let ns = text as NSString
    var out: [(Double, String)] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let nm = ns.substring(with: m.range(at: 1))
        if let o = Double(ns.substring(with: m.range(at: 2))) { out.append((o, nm)) }
    }
    return out.sorted { $0.0 < $1.0 }
}
func nameAt(_ t: Double, _ lines: [(Double, String)]) -> String? {
    var lo = 0, hi = lines.count - 1, ans: String? = nil
    while lo <= hi { let mid = (lo + hi) / 2; if lines[mid].0 <= t { ans = lines[mid].1; lo = mid + 1 } else { hi = mid - 1 } }
    return ans
}

struct Unit { let meeting: String; let date: String; let name: String; let vec: [Float]; let seconds: Double }

// Library schema — mirrors WhisperCal VoiceprintEnroller.ts so live + backfill interoperate.
struct LibSample: Codable { let embedding: [Float]; let source: String; let originalLabel: String; let activeSeconds: Double; let date: String }
struct Library: Codable { var schema: Int; var model: String; var name: String; var samples: [LibSample] }

let MODEL = "speakerkit-1.0"
let CAP_SECONDS = 1500.0
let RATE = 16000.0
let MIN_SECONDS = 5.0
let FLAG_MARGIN: Float = 0.05
let CONSISTENCY_WARN: Float = 0.45
let MAX_SAMPLES = 12

// MARK: args  ([--enroll <folder>] <m4a>...)
var argv = Array(CommandLine.arguments.dropFirst())
var enrollFolder: String? = nil
if argv.first == "--enroll", argv.count >= 2 { enrollFolder = argv[1]; argv.removeFirst(2) }
let files = argv
guard !files.isEmpty else { print("usage: VoiceprintAudit [--enroll <folder>] <m4a>..."); exit(1) }

let kit = try await SpeakerKit(PyannoteConfig())
var units: [Unit] = []

for m4a in files {
    let meeting = (m4a as NSString).lastPathComponent
        .replacingOccurrences(of: " - Transcript.m4a", with: "")
        .replacingOccurrences(of: ".m4a", with: "")
    let transcript = m4a.replacingOccurrences(of: "/Audio/", with: "/Transcripts/").replacingOccurrences(of: ".m4a", with: ".md")
    let lines = parseTranscript(transcript)
    if lines.isEmpty { print("skip (no transcript): \(meeting)"); continue }
    do {
        var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: m4a)
        let cap = Int(CAP_SECONDS * RATE); if samples.count > cap { samples = Array(samples[0..<cap]) }
        let result = try await kit.diarize(audioArray: samples, options: PyannoteDiarizationOptions())
        var votes: [Int: [String: Int]] = [:]
        var clusterSecs: [Int: Double] = [:]
        for seg in result.segments {
            guard let cid = seg.speaker.speakerId else { continue }
            clusterSecs[cid, default: 0] += Double(seg.endTime - seg.startTime)
            if let nm = nameAt(Double(seg.startTime), lines) { votes[cid, default: [:]][nm, default: 0] += 1 }
        }
        var vecsByName: [String: [[Float]]] = [:]
        var secsByName: [String: Double] = [:]
        for (cid, vec) in result.speakerCentroidEmbeddings {
            guard let best = (votes[cid] ?? [:]).max(by: { $0.value < $1.value }), !isStub(best.key) else { continue }
            let name = canon(best.key)
            vecsByName[name, default: []].append(vec)
            secsByName[name, default: 0] += clusterSecs[cid] ?? 0
        }
        var named = 0
        for (name, vecs) in vecsByName {
            let secs = secsByName[name] ?? 0
            if secs < MIN_SECONDS { continue }
            units.append(Unit(meeting: meeting, date: String(meeting.prefix(10)), name: name, vec: meanNorm(vecs), seconds: secs))
            named += 1
        }
        print("ok: \(meeting) — \(named) named, \(result.segments.count) segs")
    } catch { print("ERROR \(meeting): \(error)") }
}

// MARK: audit
print("\n========== TAG AUDIT ==========")
print("\(units.count) named speaker-instances across \(Set(units.map { $0.meeting }).count) meetings\n")

var suspectKeys = Set<String>()
var agree = 0, checkable = 0
struct Flag { let unit: Unit; let topName: String; let topCos: Float; let sameBest: Float }
var flags: [Flag] = []
for (i, u) in units.enumerated() {
    var topName = ""; var topCos: Float = -1; var sameBest: Float = -1
    for (j, o) in units.enumerated() where j != i && o.meeting != u.meeting {
        let c = cosine(u.vec, o.vec)
        if c > topCos { topCos = c; topName = o.name }
        if o.name == u.name && c > sameBest { sameBest = c }
    }
    guard sameBest >= 0 else { continue }
    checkable += 1
    if topName == u.name || topCos - sameBest < FLAG_MARGIN { agree += 1 }
    else { flags.append(Flag(unit: u, topName: topName, topCos: topCos, sameBest: sameBest)); suspectKeys.insert("\(u.meeting)\u{0}\(u.name)") }
}
print("cross-checkable instances: \(checkable) | agrees: \(agree) | suspect (excluded from enroll): \(flags.count)\n")
if flags.isEmpty {
    print("No suspect labels.\n")
} else {
    print("--- SUSPECT LABELS (excluded from enrollment) ---")
    for f in flags.sorted(by: { ($0.topCos - $0.sameBest) > ($1.topCos - $1.sameBest) }) {
        print("  [\u{0394}\(f3(f.topCos - f.sameBest))] \"\(f.unit.name)\" in \(f.unit.meeting)")
        print("        \u{21B3} matches \"\(f.topName)\" (\(f3(f.topCos))) > own clusters (\(f3(f.sameBest)))")
    }
    print("")
}

print("--- SELF-CONSISTENCY (\u{2265}2 meetings) ---")
let grouped = Dictionary(grouping: units, by: { $0.name })
for (name, us) in grouped.sorted(by: { $0.value.count > $1.value.count }) where us.count >= 2 {
    var mn: Float = 2, mx: Float = -1, sum: Float = 0, cnt = 0
    for a in 0..<us.count { for b in (a + 1)..<us.count {
        let c = cosine(us[a].vec, us[b].vec); mn = min(mn, c); mx = max(mx, c); sum += c; cnt += 1
    } }
    let mark = mn < CONSISTENCY_WARN ? "\u{26A0}" : "\u{2713}"
    print("  \(mark) \(pad(name, 22)) \(us.count) mtgs | min \(f3(mn))  avg \(f3(cnt > 0 ? sum / Float(cnt) : 0))  max \(f3(mx))")
}

// MARK: enroll
if let folder = enrollFolder {
    var byName: [String: [Unit]] = [:]
    for u in units where !suspectKeys.contains("\(u.meeting)\u{0}\(u.name)") {
        byName[u.name, default: []].append(u)
    }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var people = 0, newSamples = 0
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (name, us) in byName.sorted(by: { $0.key < $1.key }) {
        let path = "\(folder)/\(sanitizeFile(name)).json"
        var lib: Library
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONDecoder().decode(Library.self, from: data), existing.model == MODEL {
            lib = existing
        } else {
            lib = Library(schema: 1, model: MODEL, name: name, samples: [])
        }
        var seen = Set(lib.samples.map { "\($0.source)#\($0.originalLabel)" })
        for u in us {
            let key = "\(u.meeting)#backfill"
            if seen.contains(key) { continue }
            seen.insert(key)
            lib.samples.append(LibSample(embedding: u.vec, source: u.meeting, originalLabel: "backfill", activeSeconds: u.seconds, date: u.date))
            newSamples += 1
        }
        if lib.samples.count > MAX_SAMPLES { lib.samples.sort { $0.activeSeconds > $1.activeSeconds }; lib.samples = Array(lib.samples.prefix(MAX_SAMPLES)) }
        if let data = try? enc.encode(lib) { try? data.write(to: URL(fileURLWithPath: path)); people += 1 }
    }
    print("\n========== ENROLLED ==========")
    print("\(people) people, \(newSamples) samples → \(folder)")
}
