@preconcurrency import AVFoundation
import Foundation

/// Offline combine of the per-source capture WAVs (mic + system) into a single
/// mono AAC `.m4a`, time-aligned so the output's t=0 equals the session start.
///
/// Why offline `AVAudioEngine` manual rendering rather than `AVAssetExportSession`:
/// the `AppleM4A` export preset flattens to a single audio track and would drop one
/// of two sources — it can't mix. Manual rendering sums both player nodes through
/// `mainMixerNode`, streaming in chunks (low memory even for long meetings) while
/// downmixing to mono, resampling to 48 kHz, and AAC-encoding on write.
///
/// Each source is positioned by scheduling `leadFrames` of leading silence equal to
/// `firstSample − sessionStart`, so a transcript utterance at wall-clock `T` lands at
/// `T − sessionStart` in the file.
enum RecordingMixer {
    enum MixError: Error {
        case noSources
        case renderFailed
    }

    struct Source {
        let url: URL
        let firstSample: Date
    }

    private static let outputSampleRate: Double = 48_000
    private static let perSourceGain: Float = 0.8  // headroom against clipping when both overlap

    @discardableResult
    static func produce(
        mic: (url: URL, firstSample: Date)?,
        system: (url: URL, firstSample: Date)?,
        sessionStart: Date,
        outputURL: URL
    ) throws -> URL {
        let sources = [mic, system].compactMap { $0.map { Source(url: $0.url, firstSample: $0.firstSample) } }
        guard !sources.isEmpty else { throw MixError.noSources }

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1) else {
            throw MixError.renderFailed
        }

        let engine = AVAudioEngine()
        var scheduled: [(player: AVAudioPlayerNode, file: AVAudioFile, lead: AVAudioFramePosition)] = []

        for source in sources {
            let file = try AVAudioFile(forReading: source.url)
            guard file.length > 0 else { continue }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = perSourceGain

            let leadSeconds = max(0, source.firstSample.timeIntervalSince(sessionStart))
            let lead = AVAudioFramePosition((leadSeconds * outputSampleRate).rounded())
            scheduled.append((player, file, lead))
        }

        guard !scheduled.isEmpty else { throw MixError.noSources }

        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: monoFormat, maximumFrameCount: maxFrames)
        try engine.start()

        // Total render length: the latest-ending source (lead + its duration at the
        // render rate) plus a small tail so the resampler/mixer can flush.
        var totalFrames: AVAudioFramePosition = 0
        for entry in scheduled {
            let fileSeconds = Double(entry.file.length) / entry.file.processingFormat.sampleRate
            let renderFrames = AVAudioFramePosition((fileSeconds * outputSampleRate).rounded())
            totalFrames = max(totalFrames, entry.lead + renderFrames)

            let when = AVAudioTime(sampleTime: entry.lead, atRate: outputSampleRate)
            entry.player.scheduleFile(entry.file, at: when)
            entry.player.play()
        }
        totalFrames += AVAudioFramePosition(maxFrames)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            engine.stop()
            throw MixError.renderFailed
        }

        var rendered: AVAudioFramePosition = 0
        while rendered < totalFrames {
            let framesToRender = min(AVAudioFrameCount(totalFrames - rendered), maxFrames)
            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                if buffer.frameLength > 0 {
                    try outFile.write(from: buffer)
                }
                rendered += AVAudioFramePosition(buffer.frameLength)
                if buffer.frameLength == 0 { rendered = totalFrames }  // nothing left to pull
            case .insufficientDataFromInputNode:
                rendered = totalFrames
            case .cannotDoInCurrentContext:
                continue
            case .error:
                engine.stop()
                throw MixError.renderFailed
            @unknown default:
                engine.stop()
                throw MixError.renderFailed
            }
        }

        engine.stop()
        return outputURL
    }
}
