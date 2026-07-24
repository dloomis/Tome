// sckprobe — verification harness for the Wave Link own-voice bleed hypothesis.
// Modes:
//   sckprobe list
//       Enumerate SCShareableContent applications (bundleID, pid, name).
//   sckprobe capture <seconds> <spec>
//       spec: all | exclude:<bid>[,<bid>...] | only:<bid>
//       Captures display audio with that filter and prints signal statistics.
//       Discriminator: exact digital silence (all-zero samples) vs live signal.

import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

final class Collector: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    var buffers = 0
    var frames = 0
    var nonzeroFrames = 0        // |sample| > 1e-7
    var audibleFrames = 0        // |sample| > 1e-4  (~ -80 dBFS)
    var peak: Float = 0
    var sumSquares: Double = 0
    var streamError: String?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let fd = sampleBuffer.formatDescription,
              var asbd = fd.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList)
        guard status == noErr, let ch = pcm.floatChannelData else { return }

        var localPeak: Float = 0
        var localSum: Double = 0
        var localNonzero = 0
        var localAudible = 0
        let n = Int(pcm.frameLength)
        for i in 0..<n {
            let s = ch[0][i]
            let a = abs(s)
            if a > 1e-7 { localNonzero += 1 }
            if a > 1e-4 { localAudible += 1 }
            if a > localPeak { localPeak = a }
            localSum += Double(s) * Double(s)
        }
        lock.lock()
        buffers += 1
        frames += n
        nonzeroFrames += localNonzero
        audibleFrames += localAudible
        if localPeak > peak { peak = localPeak }
        sumSquares += localSum
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); streamError = "\(error)"; lock.unlock()
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let rms = frames > 0 ? sqrt(sumSquares / Double(frames)) : 0
        let db = rms > 0 ? 20 * log10(rms) : -Double.infinity
        var out = "RESULT buffers=\(buffers) frames=\(frames) nonzeroFrames=\(nonzeroFrames) audibleFrames=\(audibleFrames) peak=\(peak) rms=\(rms) rms_dBFS=\(String(format: "%.1f", db))"
        if let e = streamError { out += " streamError=\(e)" }
        return out
    }
}

func fail(_ msg: String) -> Never {
    print("FAIL \(msg)")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: sckprobe list | capture <seconds> <spec>") }

print("preflightScreenCaptureAccess=\(CGPreflightScreenCaptureAccess())")

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
} catch {
    fail("SCShareableContent: \(error)")
}

switch args[1] {
case "list":
    print("APPLICATIONS (\(content.applications.count)):")
    for app in content.applications.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) {
        print("  \(app.bundleIdentifier)  pid=\(app.processID)  \"\(app.applicationName)\"")
    }
case "capture":
    guard args.count == 4, let seconds = Double(args[2]) else { fail("usage: capture <seconds> <spec>") }
    guard let display = content.displays.first else { fail("no display") }
    let spec = args[3]

    let filter: SCContentFilter
    if spec == "all" {
        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    } else if spec.hasPrefix("exclude:") {
        let ids = Set(spec.dropFirst("exclude:".count).split(separator: ",").map(String.init))
        let apps = content.applications.filter { ids.contains($0.bundleIdentifier) }
        print("excluding \(apps.count)/\(ids.count) requested app(s): \(apps.map(\.bundleIdentifier).joined(separator: ","))")
        filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    } else if spec.hasPrefix("only:") {
        let id = String(spec.dropFirst("only:".count))
        let apps = content.applications.filter { $0.bundleIdentifier == id }
        guard !apps.isEmpty else { fail("app \(id) not found in shareable content") }
        print("including only: \(apps.map(\.bundleIdentifier).joined(separator: ","))")
        filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
    } else {
        fail("bad spec \(spec)")
    }

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.channelCount = 1
    config.sampleRate = 48000
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let collector = Collector()
    let stream = SCStream(filter: filter, configuration: config, delegate: collector)
    do {
        try stream.addStreamOutput(collector, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
    } catch {
        fail("startCapture: \(error)")
    }
    print("capturing \(seconds)s with spec=\(spec) ...")
    try? await Task.sleep(for: .seconds(seconds))
    try? await stream.stopCapture()
    print(collector.report())
default:
    fail("unknown mode \(args[1])")
}
