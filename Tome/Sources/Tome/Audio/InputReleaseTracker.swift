import Foundation

/// Pure hang-up detector for the forgotten-recording failsafe's Phase 2 probe
/// (spec 2026-10-06 §8, shadow mode): a process that had been running audio
/// INPUT for at least `minimumHoldSeconds` and then stops is the shape of a
/// call app hanging up — in any conferencing app or browser, with no bundle-ID
/// table.
///
/// No clocks and no HAL inside: the caller polls
/// `AudioProcessInspector.inputRunningBundleIDs()` on the HAL query lane and
/// feeds each ANSWERED snapshot here with its timestamp. An unanswered poll must
/// be skipped, never fed as an empty set (that would read as every process
/// hanging up at once), and a discontinuity (system sleep, a long run of
/// unanswered polls) must `reset()` instead of being fed.
///
/// Durations are measured first-seen → last-seen (the last snapshot that still
/// showed the process running), so a reported hold is one Tome actually
/// observed and errs short by under one poll interval — never long.
struct InputReleaseTracker: Sendable {
    struct Release: Equatable, Sendable {
        let bundleID: String
        /// Observed hold, whole seconds (first-seen → last-seen, floored).
        let heldSeconds: Int
    }

    struct Observation: Equatable, Sendable {
        /// Processes whose qualifying hold ended this poll, sorted by bundle ID.
        var releases: [Release] = []
        /// Processes whose current hold crossed `minimumHoldSeconds` this poll
        /// (once per hold), sorted. Lets a log reader pair holds with releases.
        var newlyHeld: [String] = []
    }

    static let defaultMinimumHoldSeconds: TimeInterval = 60

    let minimumHoldSeconds: TimeInterval
    private let excludedLower: Set<String>
    private var holds: [String: Hold] = [:]

    private struct Hold: Sendable {
        let firstSeen: Date
        var lastSeen: Date
        var crossedReported: Bool
    }

    /// `excluding` is matched case-insensitively — Tome's own bundle ID and the
    /// mix-publishing mixers, whose input is never a call.
    init(excluding: Set<String>, minimumHoldSeconds: TimeInterval = defaultMinimumHoldSeconds) {
        self.excludedLower = Set(excluding.map { $0.lowercased() })
        self.minimumHoldSeconds = minimumHoldSeconds
    }

    /// Feed one answered snapshot of the processes running input at `now`.
    mutating func observe(running: Set<String>, now: Date) -> Observation {
        let considered = running.filter { !excludedLower.contains($0.lowercased()) }
        var observation = Observation()

        for (bundleID, hold) in holds where !considered.contains(bundleID) {
            holds[bundleID] = nil
            let held = hold.lastSeen.timeIntervalSince(hold.firstSeen)
            if held >= minimumHoldSeconds {
                observation.releases.append(Release(bundleID: bundleID, heldSeconds: Int(held)))
            }
        }

        for bundleID in considered {
            var hold = holds[bundleID] ?? Hold(firstSeen: now, lastSeen: now, crossedReported: false)
            hold.lastSeen = now
            if !hold.crossedReported, now.timeIntervalSince(hold.firstSeen) >= minimumHoldSeconds {
                hold.crossedReported = true
                observation.newlyHeld.append(bundleID)
            }
            holds[bundleID] = hold
        }

        observation.releases.sort { $0.bundleID < $1.bundleID }
        observation.newlyHeld.sort()
        return observation
    }

    /// Forget every hold. For discontinuities — continuity across the gap was
    /// never observed, so nothing that ends after it may count as a release.
    mutating func reset() {
        holds = [:]
    }
}
