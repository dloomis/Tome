/// User-selectable ASR model. Raw values are persisted in UserDefaults —
/// treat them as a stable on-disk format.
enum TranscriberModel: String, CaseIterable, Sendable, Codable {
    case parakeetTDTv3 = "parakeet-tdt-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    var displayName: String {
        switch self {
        case .parakeetTDTv3: "Parakeet-TDT v3"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    /// One-line description shown under the model's name in Settings.
    var pickerSubtitle: String {
        switch self {
        case .parakeetTDTv3: "Fast, streaming-optimized (default)"
        case .whisperLargeV3Turbo: "Higher accuracy, larger download"
        }
    }

    /// Unknown raw values (from a future or rolled-back build) fall back to
    /// the default model rather than crashing or resetting UserDefaults.
    static func from(persisted: String?) -> TranscriberModel {
        persisted.flatMap(TranscriberModel.init(rawValue:)) ?? .parakeetTDTv3
    }
}

extension TranscriberModel {
    /// Whether the model's files are fully on disk (offline load possible).
    /// Filesystem checks — cheap (fileExists), but call from UI only.
    var isInstalled: Bool {
        switch self {
        case .parakeetTDTv3: ParakeetBackend.isInstalled()
        case .whisperLargeV3Turbo: WhisperBackend.isInstalled()
        }
    }

    /// Approximate download size for Settings copy. Whisper's depends on the
    /// device-resolved variant (M1 gets the quantized build).
    var approxDownloadSize: String {
        switch self {
        case .parakeetTDTv3: "~600 MB"
        case .whisperLargeV3Turbo:
            WhisperBackend.resolveVariant().hasSuffix("_626MB") ? "~0.6 GB" : "~1.5 GB"
        }
    }
}
