@preconcurrency import AVFoundation
import FluidAudio
import WhisperKit

/// OpenAI Whisper Large v3 Turbo via WhisperKit.
///
/// Variant note: the turbo model is the `openai_whisper-large-v3-v20240930*`
/// family. `openai_whisper-large-v3_turbo` — the name that LOOKS right — is
/// large-v3 with WhisperKit compression, a different (slower) model.
final actor WhisperBackend: ASRBackend {
    nonisolated let model: TranscriberModel = .whisperLargeV3Turbo
    private var whisperKit: WhisperKit?

    private static let variantFamily = "openai_whisper-large-v3-v20240930"

    /// Full precision where Argmax's device matrix supports it (M2+),
    /// otherwise the quantized build (the only supported variant on M1).
    /// An unrecognized device class (family absent from `supported`) falls
    /// through to the `_626MB` build as a best-effort default.
    static func resolveVariant(supported: [String]) -> String {
        supported.contains(variantFamily) ? variantFamily : variantFamily + "_626MB"
    }

    static func resolveVariant() -> String {
        resolveVariant(supported: WhisperKit.recommendedModels().supported)
    }

    /// Explicit root under our own Application Support. WhisperKit's default
    /// downloadBase is ~/Documents/huggingface — 1.5 GB of model files in
    /// visible documents plus a TCC prompt. tokenizerFolder is left nil so it
    /// falls back to this same base: one root for isInstalled() to check.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tome/WhisperKit", isDirectory: true)
    }

    /// HubApi layout: downloadBase/models/<org>/<repo>/<variant>.
    static func modelFolder(variant: String) -> URL {
        downloadBase.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// The tokenizer is fetched from a DIFFERENT repo (openai/whisper-large-v3)
    /// on first load; offline loads fail without it, so isInstalled() includes it.
    static var tokenizerJSON: URL {
        downloadBase.appendingPathComponent("models/openai/whisper-large-v3/tokenizer.json")
    }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        let folder = modelFolder(variant: resolveVariant())
        let hasCore = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlpackage").path)
        }
        return hasCore && fm.fileExists(atPath: tokenizerJSON.path)
    }

    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws {
        guard whisperKit == nil else { return }
        let variant = Self.resolveVariant()
        let folder: URL
        if Self.isInstalled() {
            folder = Self.modelFolder(variant: variant)
            onEvent(.loading)
        } else {
            onEvent(.downloading(progress: 0))
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.downloadBase,
                progressCallback: { progress in
                    onEvent(.downloading(progress: progress.fractionCompleted))
                }
            )
            onEvent(.loading)
        }
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Self.downloadBase,
            modelFolder: folder.path,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(samples: [Float], language: Language) async throws -> ASRResult {
        guard let whisperKit else { throw ASRCoordinatorError.notInitialized }
        let start = ContinuousClock.now
        let options = DecodingOptions(task: .transcribe, language: language.rawValue)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = start.duration(to: .now)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Map Whisper's per-segment avg log-prob onto ASRResult's 0…1 confidence.
        let segments = results.flatMap(\.segments)
        let confidence: Float
        if segments.isEmpty {
            confidence = 0
        } else {
            let avgLogProb = segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
            confidence = min(max(exp(avgLogProb), 0), 1)
        }
        return ASRResult(
            text: text,
            confidence: confidence,
            duration: Double(samples.count) / 16_000.0,
            processingTime: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult {
        try await transcribe(samples: Self.samples16k(from: buffer), language: language)
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    /// Convert any PCM buffer to the 16 kHz mono Float32 Whisper expects.
    /// (Parakeet's AsrManager does this internally for its buffer overload;
    /// WhisperKit's array API expects pre-converted samples.) Mirrors
    /// StreamingTranscriber.extractSamples without the converter cache — the
    /// buffer overload only runs in batch re-transcription, not per-chunk.
    static func samples16k(from buffer: AVAudioPCMBuffer) -> [Float] {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        if buffer.format == targetFormat, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return [] }
        let ratio = 16_000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        converter.convert(to: out, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
