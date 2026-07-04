import AVFoundation
import Foundation

// Standalone assertion harness for MicCapture's multi-channel handling:
//   1. makeTapFormat — must produce a usable tap format for >2-channel devices
//      (AirPods HFP / aggregates report 3 channels; the "standard" initializer
//      returns nil there, which was the MIC-4-FAIL dead end).
//   2. downmixToMono — audio on ANY channel must survive into the mono buffer
//      (the old code read channel 0 only, so an aggregate whose mic landed on
//      channel 2 recorded pure silence).
// Compiled with the real MicCapture.swift + WAVStreamWriter.swift by
// scripts/run_miccapture_check.sh. diagLog is stubbed (lives in TranscriptionEngine).
func diagLog(_ msg: String) {}

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok: \(msg)") }
    else { print("  FAIL: \(msg)"); failures += 1 }
}

/// Deinterleaved float32 format with `channels` channels (uses an explicit layout
/// for >2 channels, mirroring how CoreAudio reports HFP/aggregate devices).
func makeFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat {
    if channels <= 2 {
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    }
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | channels
    let chLayout = withUnsafePointer(to: &layout) { AVAudioChannelLayout(layout: $0) }
    return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: chLayout)
}

print("case: tap format for a 3-channel 24kHz device (AirPods HFP / aggregate)")
do {
    let threeCh = makeFormat(sampleRate: 24_000, channels: 3)
    check(AVAudioFormat(standardFormatWithSampleRate: threeCh.sampleRate, channels: threeCh.channelCount) == nil,
          "precondition: standard initializer really does fail for 3 channels")
    let tap = MicCapture.makeTapFormat(from: threeCh)
    check(tap != nil, "makeTapFormat returns a usable format for 3 channels")
    check(tap?.sampleRate == 24_000, "tap format keeps the device sample rate")
}

print("case: tap format for a normal mono 48kHz device is the standard one")
do {
    let mono = makeFormat(sampleRate: 48_000, channels: 1)
    let tap = MicCapture.makeTapFormat(from: mono)
    check(tap != nil && tap!.channelCount == 1 && tap!.sampleRate == 48_000,
          "mono passthrough unchanged")
}

print("case: downmix 3-channel buffer with audio ONLY on channel 2")
do {
    let fmt = makeFormat(sampleRate: 24_000, channels: 3)
    let frames: AVAudioFrameCount = 2400
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    // channels 0 and 1 silent; channel 2 carries a 0.6-amplitude signal
    for i in 0..<Int(frames) {
        buf.floatChannelData![0][i] = 0
        buf.floatChannelData![1][i] = 0
        buf.floatChannelData![2][i] = 0.6
    }
    let mono = MicCapture.downmixToMono(buf)
    check(mono != nil, "downmix produces a buffer")
    if let mono {
        check(mono.format.channelCount == 1, "downmix output is mono")
        check(mono.frameLength == frames, "downmix preserves frame count")
        let ch = mono.floatChannelData![0]
        var sum: Float = 0
        for i in 0..<Int(mono.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(mono.frameLength)).squareRoot()
        check(rms > 0.15, "audio on channel 2 survives the downmix (rms=\(rms), was 0.0 with channel-0-only capture)")
        check(abs(rms - 0.2) < 0.02, "downmix averages channels (0.6/3 = 0.2, got \(rms))")
    }
}

print("case: downmix of an already-mono buffer preserves samples")
do {
    let fmt = makeFormat(sampleRate: 48_000, channels: 1)
    let frames: AVAudioFrameCount = 480
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.25 }
    let mono = MicCapture.downmixToMono(buf)
    check(mono != nil && mono!.floatChannelData![0][100] == 0.25 && mono!.frameLength == frames,
          "mono in == mono out")
}

if failures == 0 { print("ALL PASSED"); exit(0) }
else { print("\(failures) CHECK(S) FAILED"); exit(1) }
