@preconcurrency import ScreenCaptureKit
import CoreGraphics

/// Passive detection of the active meeting (and its name) by reading window titles
/// via `SCShareableContent` — the same screen-recording permission Tome already holds
/// for system-audio capture. Enumerating windows never starts an `SCStream`, so it
/// neither lights the recording indicator nor needs a new permission, and we gate on
/// `CGPreflightScreenCaptureAccess()` so passive polling never triggers a prompt.
///
/// Title extraction is heuristic and per-app — formats drift across app versions and
/// OS locales — so this is a *suggestion*: the UI shows a dismissible chip and the
/// recording user can ignore any false match (see ControlBar's meeting chip). v1
/// reliably names Teams and Google Meet; Zoom exposes only a generic "Zoom Meeting"
/// window with no topic, and the rest are best-effort (no name → no suggestion).

enum ConferencingFamily: Sendable { case teams, zoom, meetBrowser, webex, facetime, slack }

struct ConferencingApp: Sendable {
    let displayName: String
    let family: ConferencingFamily
}

/// Canonical conferencing-app table — the single source of truth for "is this a call
/// app", shared by `MeetingDetector` and `ContentView.startSession`'s source-app lookup.
let conferencingApps: [String: ConferencingApp] = [
    "com.microsoft.teams2": ConferencingApp(displayName: "Teams", family: .teams),
    "com.microsoft.teams": ConferencingApp(displayName: "Teams", family: .teams),
    "us.zoom.xos": ConferencingApp(displayName: "Zoom", family: .zoom),
    "com.apple.FaceTime": ConferencingApp(displayName: "FaceTime", family: .facetime),
    "com.tinyspeck.slackmacgap": ConferencingApp(displayName: "Slack", family: .slack),
    "com.cisco.webexmeetingsapp": ConferencingApp(displayName: "Webex", family: .webex),
    "Cisco-Systems.Spark": ConferencingApp(displayName: "Webex", family: .webex),
    "com.google.Chrome": ConferencingApp(displayName: "Chrome", family: .meetBrowser),
    "company.thebrowser.Browser": ConferencingApp(displayName: "Arc", family: .meetBrowser),
    "com.apple.Safari": ConferencingApp(displayName: "Safari", family: .meetBrowser),
    "com.microsoft.edgemac": ConferencingApp(displayName: "Edge", family: .meetBrowser),
]

/// Friendly name for a conferencing bundle ID (e.g. "Teams"), or nil if not a call app.
func conferencingAppName(_ bundleID: String) -> String? {
    conferencingApps[bundleID]?.displayName
}

/// A detected, named meeting. `title` is always a real extracted name — we never
/// fabricate one, so an app that's in a call but exposes no topic yields nil from `scan`.
struct DetectedMeeting: Equatable, Sendable {
    let appName: String   // "Teams" | "Google Meet" | …
    let bundleID: String
    let title: String
}

enum MeetingDetector {

    /// Scan on-screen windows for a named meeting. `frontmostBundleID` (read on the
    /// MainActor by the caller) breaks ties toward the app the user is looking at.
    /// Returns nil when permission isn't granted, nothing matches, or no name is found.
    static func scan(frontmostBundleID: String?) async -> DetectedMeeting? {
        // Never trigger a permission prompt from passive polling.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        // Extract only value types here — SCWindow / SCRunningApplication are not
        // Sendable and must not escape this function.
        struct Candidate { let title: String; let bundleID: String; let app: ConferencingApp }
        var candidates: [Candidate] = []
        for window in content.windows {
            guard window.windowLayer == 0,
                  let title = window.title, !title.isEmpty,
                  window.frame.width > 200, window.frame.height > 200,
                  let bundleID = window.owningApplication?.bundleIdentifier,
                  let app = conferencingApps[bundleID] else { continue }
            candidates.append(Candidate(title: title, bundleID: bundleID, app: app))
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer the frontmost app's windows, then a fixed family priority.
        let familyPriority: [ConferencingFamily] = [.teams, .meetBrowser, .zoom, .webex, .facetime, .slack]
        func rank(_ c: Candidate) -> Int {
            let front = (frontmostBundleID != nil && c.bundleID == frontmostBundleID) ? -1000 : 0
            return front + (familyPriority.firstIndex(of: c.app.family) ?? familyPriority.count)
        }

        for c in candidates.sorted(by: { rank($0) < rank($1) }) {
            let name: String?
            let appName: String
            switch c.app.family {
            case .teams:       name = extractTeams(c.title); appName = c.app.displayName
            case .meetBrowser: name = extractMeet(c.title);  appName = "Google Meet"
            case .zoom:        name = extractZoom(c.title);  appName = c.app.displayName
            case .webex, .facetime, .slack: name = nil; appName = c.app.displayName
            }
            if let name {
                return DetectedMeeting(appName: appName, bundleID: c.bundleID, title: name)
            }
        }
        return nil
    }

    // MARK: - Per-app title extractors (pure, individually testable)

    /// Teams meeting windows are titled "<subject> | Microsoft Teams" (and the meeting
    /// window is distinct from the nav window titled "Chat | Microsoft Teams", etc.).
    static func extractTeams(_ title: String) -> String? {
        var name = droppingSuffix(" | Microsoft Teams", from: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Meeting in ", "Meeting with "] where name.lowercased().hasPrefix(prefix.lowercased()) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let navLabels: Set<String> = [
            "", "microsoft teams", "chat", "calendar", "activity",
            "teams", "calls", "files", "apps", "help", "settings",
        ]
        return navLabels.contains(name.lowercased()) ? nil : name
    }

    /// Google Meet runs in a browser; the window title is the active tab. Named calls
    /// read "Meet - <name>" or "<name> - Google Meet"; an unnamed call is the bare
    /// "abc-defg-hij" code, and the landing page is just "Meet"/"Google Meet".
    static func extractMeet(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        for suffix in [" - Google Meet", " – Google Meet", " — Google Meet"] where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            name = String(trimmed.dropLast(suffix.count))
            break
        }
        if name == nil {
            for prefix in ["Meet - ", "Meet – ", "Meet — "] where trimmed.hasPrefix(prefix) {
                name = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        guard let result = name?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        let lower = result.lowercased()
        if lower == "meet" || lower == "google meet" { return nil }
        // Bare meeting code (e.g. "abc-defg-hij") — an unnamed call, no useful name.
        if result.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }
        return result
    }

    /// Zoom's in-call window is the generic "Zoom Meeting" with no topic, so v1 offers
    /// no name (the call is still capturable; it just falls back to the default label).
    static func extractZoom(_ title: String) -> String? { nil }

    private static func droppingSuffix(_ suffix: String, from s: String) -> String {
        s.lowercased().hasSuffix(suffix.lowercased()) ? String(s.dropLast(suffix.count)) : s
    }
}
