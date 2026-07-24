import CoreAudio
import Foundation

/// Read-only view over CoreAudio's process objects
/// (`kAudioHardwarePropertyProcessObjectList`) — which processes are currently
/// running audio input/output. No TCC prompt: this is attribution metadata, not
/// audio content.
///
/// Used as a WARN-ONLY diagnostic at session start: a process running input AND
/// output simultaneously is the signature of a mic-pass-through audio router
/// (Wave Link, Krisp, …) whose rendered audio ScreenCaptureKit will attribute
/// to that process and mix into the system leg as phantom "Them" speech. It
/// must never drive automatic exclusion — a conferencing app in a live call
/// carries the identical signature, and excluding one silently drops the
/// far-end audio (see docs/superpowers/specs/2026-07-24-own-voice-bleed-*.md).
enum AudioProcessInspector {
    /// Bundle IDs of processes currently running BOTH audio input and output,
    /// minus `excluding` (case-insensitive). Sorted for stable log output.
    static func micPassthroughBundleIDs(excluding: Set<String> = []) -> [String] {
        let excludedLower = Set(excluding.map { $0.lowercased() })
        let processObjects = arrayProperty(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            as: AudioObjectID.self
        )
        var found: Set<String> = []
        for object in processObjects {
            guard scalarProperty(of: object, selector: kAudioProcessPropertyIsRunningInput) == 1,
                  scalarProperty(of: object, selector: kAudioProcessPropertyIsRunningOutput) == 1,
                  let bundleID = stringProperty(of: object, selector: kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty,
                  !excludedLower.contains(bundleID.lowercased())
            else { continue }
            found.insert(bundleID)
        }
        return found.sorted()
    }

    private static func arrayProperty<T>(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        as type: T.Type
    ) -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<T>.stride
        var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &result) == noErr else {
            return []
        }
        return result
    }

    private static func scalarProperty(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }
}
