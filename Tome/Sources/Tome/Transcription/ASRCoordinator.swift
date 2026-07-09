@preconcurrency import AVFoundation
import FluidAudio

/// Serializes all access to the active ASR backend. All ASR — live
/// `StreamingTranscriber` and batch `SegmentReTranscriber` — routes through
/// this actor. Model download/load lives in `ModelProvisioner`; the
/// coordinator only ever *receives* a prepared backend via `install`.
///
/// Reentrancy note: `transcribe` suspends at the backend call, so `install`
/// can run while calls are in flight on the old backend. The reference swap
/// is safe (in-flight calls hold their own reference), but `unload()` — which
/// actively releases CoreML models — is deferred until the retired backend's
/// in-flight count drains to zero.
actor ASRCoordinator {
    private var activeBackend: (any ASRBackend)?
    /// Highest install token applied so far. Installs carry the provisioning
    /// cycle's monotonic generation; an install whose token is not strictly
    /// greater is stale (its cycle was superseded — e.g. a flip-back re-asserted
    /// the serving backend under a higher token while this install was in flight)
    /// and is refused, its incoming backend unloaded. Prevents a late install
    /// from a dead cycle silently swapping in the wrong backend (audit F-1).
    private var lastInstallToken = Int.min
    /// In-flight transcribe calls per backend (keyed by identity).
    private var inFlight: [ObjectIdentifier: Int] = [:]
    /// Replaced backends still owed an unload once their in-flight drains.
    private var retired: [ObjectIdentifier: any ASRBackend] = [:]
    /// Pushed in from `AppSettings.transcriptionLanguage` whenever it changes.
    /// Used by Parakeet v3 for script-aware token filtering; maps to Whisper's
    /// ISO-639-1 language option.
    private var currentLanguage: Language = .english

    var isReady: Bool { activeBackend != nil }
    var activeModel: TranscriberModel? { activeBackend?.model }

    func setLanguage(_ language: Language) {
        currentLanguage = language
    }

    /// Swap the serving backend. The old backend keeps serving its in-flight
    /// calls and is unloaded when the last one returns.
    ///
    /// `token` is the requesting provisioning cycle's generation. Installs are
    /// token-ordered: a `token` not strictly greater than the last applied one
    /// is stale — the swap is refused and the incoming backend unloaded (unless
    /// it IS the active backend, which stays put). Re-asserting the active
    /// backend under a higher token is a no-op swap (the `old !== backend`
    /// guard skips the retire), but still records the token so any in-flight
    /// stale install is outranked.
    func install(backend: any ASRBackend, token: Int) async {
        guard token > lastInstallToken else {
            // Stale cycle. Don't disturb the active backend; release the
            // orphaned incoming one unless it's already what's serving.
            if activeBackend !== backend {
                await backend.unload()
            }
            return
        }
        lastInstallToken = token
        if let old = activeBackend, old !== backend {
            let id = ObjectIdentifier(old)
            if inFlight[id, default: 0] > 0 {
                retired[id] = old
            } else {
                await old.unload()
            }
        }
        activeBackend = backend
    }

    func transcribe(samples: [Float], source: AudioSource) async throws -> ASRResult {
        let backend = try currentBackend()
        begin(backend)
        do {
            let result = try await backend.transcribe(samples: samples, language: currentLanguage)
            await end(backend)
            return result
        } catch {
            await end(backend)
            throw error
        }
    }

    func transcribe(buffer: AVAudioPCMBuffer, source: AudioSource) async throws -> ASRResult {
        let backend = try currentBackend()
        begin(backend)
        do {
            let result = try await backend.transcribe(buffer: buffer, language: currentLanguage)
            await end(backend)
            return result
        } catch {
            await end(backend)
            throw error
        }
    }

    private func currentBackend() throws -> any ASRBackend {
        guard let activeBackend else { throw ASRCoordinatorError.notInitialized }
        return activeBackend
    }

    private func begin(_ backend: any ASRBackend) {
        inFlight[ObjectIdentifier(backend), default: 0] += 1
    }

    private func end(_ backend: any ASRBackend) async {
        let id = ObjectIdentifier(backend)
        inFlight[id, default: 1] -= 1
        if inFlight[id] == 0 {
            inFlight[id] = nil
            if let toUnload = retired.removeValue(forKey: id) {
                await toUnload.unload()
            }
        }
    }
}

enum ASRCoordinatorError: Error, Sendable {
    case notInitialized
}

extension ASRCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "Transcription model not ready — check Settings ▸ Transcription"
        }
    }
}
