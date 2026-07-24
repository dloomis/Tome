import CoreAudio
import Testing

@testable import Tome

// Tests for the 2026-07-24 own-voice-bleed spec: audio-router exclusion,
// UID-persisted mic selection, and the pure fallback predicate. All pure
// functions — no audio hardware, no UserDefaults.

@Suite("System-audio exclusion merge")
struct ExclusionMergeTests {
    @Test func userListMergesWithBuiltinNoiseApps() {
        let merged = SystemAudioCapture.exclusionBundleIDs(userList: ["com.elgato.WaveLink3"])
        #expect(merged.contains("com.elgato.wavelink3"))
        // The hardcoded media-player exclusions must survive the merge.
        #expect(merged.contains("com.spotify.client"))
        #expect(merged.contains("com.apple.music"))
    }

    @Test func matchingIsCaseInsensitive() {
        let merged = SystemAudioCapture.exclusionBundleIDs(userList: ["Com.Elgato.WaveLink3"])
        #expect(merged.contains("com.elgato.wavelink3"))
    }

    @Test func emptyUserListLeavesOnlyNoiseApps() {
        let merged = SystemAudioCapture.exclusionBundleIDs(userList: [])
        #expect(!merged.isEmpty)
        #expect(!merged.contains("com.elgato.wavelink3"))
    }

    @Test func unknownIDsAreCarriedVerbatimLowercased() {
        // An ID that matches no running app is a harmless no-op at filter time,
        // but it must still be present in the set (it protects a future launch).
        let merged = SystemAudioCapture.exclusionBundleIDs(userList: ["com.example.FutureRouter"])
        #expect(merged.contains("com.example.futurerouter"))
    }
}

@Suite("Exclusion list seeding")
struct ExclusionSeedingTests {
    @Test func firstRunSeedsAllBuiltins() {
        let result = AppSettings.seededExclusions(current: nil, seen: nil, builtins: ["a", "b"])
        #expect(result.list == ["a", "b"])
        #expect(result.seen == ["a", "b"])
    }

    @Test func userRemovalSticks() {
        // "a" was seeded and then removed by the user; it stays in `seen`, so
        // re-running the seeding must NOT resurrect it.
        let result = AppSettings.seededExclusions(current: ["b"], seen: ["a", "b"], builtins: ["a", "b"])
        #expect(result.list == ["b"])
    }

    @Test func newBuiltinJoinsExistingInstallOnce() {
        let first = AppSettings.seededExclusions(current: ["a"], seen: ["a"], builtins: ["a", "c"])
        #expect(first.list == ["a", "c"])
        #expect(first.seen == ["a", "c"])
        // Idempotent on the next launch.
        let second = AppSettings.seededExclusions(current: first.list, seen: first.seen, builtins: ["a", "c"])
        #expect(second.list == first.list)
        #expect(second.seen == first.seen)
    }

    @Test func userAdditionsArePreserved() {
        let result = AppSettings.seededExclusions(
            current: ["a", "com.custom.router"],
            seen: ["a"],
            builtins: ["a", "b"]
        )
        #expect(result.list == ["a", "com.custom.router", "b"])
    }

    @Test func builtinAlreadyPresentButUnseenIsNotDuplicated() {
        // User hand-added an ID that later becomes a builtin default.
        let result = AppSettings.seededExclusions(current: ["a"], seen: [], builtins: ["a"])
        #expect(result.list == ["a"])
        #expect(result.seen == ["a"])
    }
}

@Suite("Mic selection migration")
struct MicSelectionMigrationTests {
    @Test func storedUIDAlwaysWins() {
        let result = AppSettings.migratedInputSelection(
            storedUID: "uid-1",
            storedName: "USB Mic",
            legacyID: 42,
            resolveUID: { _ in "should-not-be-used" },
            resolveName: { _ in "wrong" }
        )
        #expect(result.uid == "uid-1")
        #expect(result.name == "USB Mic")
    }

    @Test func legacyIDResolvesWhenDevicePresent() {
        let result = AppSettings.migratedInputSelection(
            storedUID: nil,
            storedName: nil,
            legacyID: 42,
            resolveUID: { id in id == 42 ? "uid-42" : nil },
            resolveName: { id in id == 42 ? "XLR Dock" : nil }
        )
        #expect(result.uid == "uid-42")
        #expect(result.name == "XLR Dock")
    }

    @Test func legacyIDUnresolvableFallsBackToDefault() {
        // Device absent at migration time — same outcome the old boot sanitizer
        // produced, but only when the id is genuinely unresolvable.
        let result = AppSettings.migratedInputSelection(
            storedUID: nil,
            storedName: nil,
            legacyID: 42,
            resolveUID: { _ in nil },
            resolveName: { _ in nil }
        )
        #expect(result.uid == "")
        #expect(result.name == "")
    }

    @Test func legacyZeroMeansSystemDefault() {
        let result = AppSettings.migratedInputSelection(
            storedUID: nil,
            storedName: nil,
            legacyID: 0,
            resolveUID: { _ in
                Issue.record("resolver must not be called for legacy id 0")
                return nil
            },
            resolveName: { _ in nil }
        )
        #expect(result.uid == "")
    }
}

@Suite("Mic fallback predicate")
struct MicFallbackPredicateTests {
    @Test func systemDefaultSelectionIsNeverAFallback() {
        #expect(!TranscriptionEngine.isMicFallbackActive(
            selectedUID: "", selectionResolvesTo: nil, boundDeviceID: 7
        ))
    }

    @Test func boundToSelectedDeviceClearsFallback() {
        #expect(!TranscriptionEngine.isMicFallbackActive(
            selectedUID: "uid-1", selectionResolvesTo: 7, boundDeviceID: 7
        ))
    }

    @Test func unresolvableSelectionIsAFallback() {
        #expect(TranscriptionEngine.isMicFallbackActive(
            selectedUID: "uid-1", selectionResolvesTo: nil, boundDeviceID: 7
        ))
    }

    @Test func boundElsewhereWhileSelectionResolvableIsAFallback() {
        // Emergency default rebind after a failed bind: the selection resolves
        // (device present) but capture is running on another device.
        #expect(TranscriptionEngine.isMicFallbackActive(
            selectedUID: "uid-1", selectionResolvesTo: 7, boundDeviceID: 9
        ))
    }
}
