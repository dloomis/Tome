// caprobe — enumerate CoreAudio process objects: which processes are running
// audio I/O, and against which devices. No TCC required (metadata only).
import CoreAudio
import Foundation

func getData<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type) -> [T] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &result) == noErr else { return [] }
    return result
}

func getString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value as String
}

func getUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    getData(objectID, selector, UInt32.self).first
}

let processObjects = getData(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
print("PROCESS OBJECTS: \(processObjects.count)")
for obj in processObjects {
    let pid = getData(obj, kAudioProcessPropertyPID, pid_t.self).first ?? -1
    let bundleID = getString(obj, kAudioProcessPropertyBundleID) ?? "?"
    let isRunning = getUInt32(obj, kAudioProcessPropertyIsRunning) ?? 0
    let runInput = getUInt32(obj, kAudioProcessPropertyIsRunningInput) ?? 0
    let runOutput = getUInt32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
    let devices = getData(obj, kAudioProcessPropertyDevices, AudioObjectID.self)
    let deviceNames = devices.map { getString($0, kAudioObjectPropertyName) ?? "dev\($0)" }
    // Only print rows with any activity or a real bundle id, to keep output scannable
    if isRunning != 0 || runInput != 0 || runOutput != 0 || bundleID != "" {
        print("pid=\(pid) bundle=\(bundleID.isEmpty ? "-" : bundleID) running=\(isRunning) input=\(runInput) output=\(runOutput) devices=[\(deviceNames.joined(separator: " | "))]")
    }
}
