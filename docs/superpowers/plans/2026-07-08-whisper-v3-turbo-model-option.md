# Whisper Large v3 Turbo Model Option — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Whisper Large v3 Turbo (WhisperKit) as a user-selectable transcription model alongside Parakeet-TDT v3, with lazy download, readiness-gated recording, and auto-revert on failure.

**Architecture:** An `ASRBackend` protocol with Parakeet/Whisper actor conformances sits behind the existing `ASRCoordinator` actor (whose transcribe surface is unchanged — `StreamingTranscriber`/`SegmentReTranscriber` untouched). A new `@MainActor @Observable ModelProvisioner` is the only component that downloads/loads models, driving a generation-guarded state machine (`servingModel` / `activity` / `lastFailure`) that gates the UI and API.

**Tech Stack:** Swift 6.2 / SwiftPM, SwiftUI, FluidAudio 0.15.1 (Parakeet), argmax-oss-swift pinned `94cf6b1` (WhisperKit), swift-testing.

**Spec:** `docs/superpowers/specs/2026-07-08-whisper-v3-turbo-model-option-design.md` — read it before starting. The spec is the authority on behavior; this plan is the authority on mechanics.

## Global Constraints

- Branch: `whisper-v3-turbo-model-option` (already created, off `resilience-full`). Commit after every task; end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **All builds/tests run from the `Tome/` subdirectory** (Package.swift lives at `Tome/Package.swift`): `cd /Users/nic/programming/tome/Tome && swift build` / `swift test`.
- `swift test` needs the full Xcode toolchain (swift-testing ships with Xcode, not CommandLineTools). If `swift test` fails with a Testing-framework error, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app`.
- Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) — never XCTest. Async waits use poll loops (`for _ in 0..<100 { … try await Task.sleep(for: .milliseconds(50)) }`), the codebase's established pattern.
- Platform floor is macOS 26 (`platforms: [.macOS(.v26)]`), Swift tools 6.2, strict concurrency. New types must be `Sendable`-correct.
- **API freeze**: no response-shape changes to the local HTTP API. New failure responses reuse the existing `(Int, String)` raw-JSON-literal pattern. `HealthResponse` fields unchanged.
- UserDefaults keys (exact): `"transcriberModel"`, `"lastGoodTranscriberModel"`.
- WhisperKit variant family (exact): `openai_whisper-large-v3-v20240930`. **Never use `openai_whisper-large-v3_turbo`** — despite the name it is NOT Large v3 Turbo (it's large-v3 with WhisperKit compression).
- Model display names (exact, used in UI and status strings): `Parakeet-TDT v3`, `Whisper Large v3 Turbo`.
- The engine's `assetStatus` strings are string-matched by `APIServer` (`contains("Transcribing")`, `contains("Loading")`, `== "Ready"`). Provisioning status is **never** routed through `assetStatus`.
- Whisper model files root (exact): `~/Library/Application Support/Tome/WhisperKit` (via `FileManager.default.urls(for: .applicationSupportDirectory, …)`). Parakeet files stay wherever FluidAudio puts them (`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`).
- DRY: reuse `TestSupport` helpers in tests; follow existing file/comment style (comments explain *why*, not *what*).
- **Git cwd**: build steps `cd` into `Tome/`, but every commit block's `git add` paths are repo-root-relative — run all git commands from `/Users/nic/programming/tome` (i.e. `cd /Users/nic/programming/tome` before the `git add`, or use `git -C /Users/nic/programming/tome …`).

---

### Task 1: `TranscriberModel` enum + `AppSettings.transcriberModel`

**Files:**
- Create: `Tome/Sources/Tome/Transcription/TranscriberModel.swift`
- Modify: `Tome/Sources/Tome/Settings/AppSettings.swift` (property block ~line 25, init ~line 116)
- Test: `Tome/Tests/TomeTests/TranscriberModelTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum TranscriberModel: String, CaseIterable, Sendable, Codable` with cases `.parakeetTDTv3` (raw `"parakeet-tdt-v3"`), `.whisperLargeV3Turbo` (raw `"whisper-large-v3-turbo"`); `var displayName: String`; `var pickerSubtitle: String`; `static func from(persisted: String?) -> TranscriberModel`. `AppSettings.transcriberModel: TranscriberModel` (persists on set, key `"transcriberModel"`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Tome

@Suite struct TranscriberModelTests {
    @Test func rawValuesAreStable() {
        // Persisted in UserDefaults — changing them silently resets user selections.
        #expect(TranscriberModel.parakeetTDTv3.rawValue == "parakeet-tdt-v3")
        #expect(TranscriberModel.whisperLargeV3Turbo.rawValue == "whisper-large-v3-turbo")
    }

    @Test func displayNames() {
        #expect(TranscriberModel.parakeetTDTv3.displayName == "Parakeet-TDT v3")
        #expect(TranscriberModel.whisperLargeV3Turbo.displayName == "Whisper Large v3 Turbo")
    }

    @Test func unknownPersistedValueFallsBackToParakeet() {
        #expect(TranscriberModel.from(persisted: "some-future-model") == .parakeetTDTv3)
        #expect(TranscriberModel.from(persisted: nil) == .parakeetTDTv3)
        #expect(TranscriberModel.from(persisted: "whisper-large-v3-turbo") == .whisperLargeV3Turbo)
    }

    /// Spec §9 test 2's persistence clause: selection writes — including the
    /// provisioner's revert write — go through didSet and land in UserDefaults,
    /// so a revert survives relaunch. AppSettings hardcodes .standard; save and
    /// restore the key around the test.
    @Test @MainActor func appSettingsPersistsSelectionThroughDidSet() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "transcriberModel")
        defer {
            if let saved { defaults.set(saved, forKey: "transcriberModel") }
            else { defaults.removeObject(forKey: "transcriberModel") }
        }
        let settings = AppSettings()
        settings.transcriberModel = .whisperLargeV3Turbo
        #expect(defaults.string(forKey: "transcriberModel") == "whisper-large-v3-turbo")
        settings.transcriberModel = .parakeetTDTv3   // shape of the F1 revert write
        #expect(defaults.string(forKey: "transcriberModel") == "parakeet-tdt-v3")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter TranscriberModelTests`
Expected: compile FAILURE — `cannot find 'TranscriberModel' in scope`.

- [ ] **Step 3: Write the enum**

`Tome/Sources/Tome/Transcription/TranscriberModel.swift`:

```swift
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
```

- [ ] **Step 4: Add the setting**

In `Tome/Sources/Tome/Settings/AppSettings.swift`, after the `transcriptionLanguage` property (line ~25):

```swift
    /// Which ASR model transcribes. Selection is lazy — changing it triggers a
    /// background download/load via ModelProvisioner; recording is gated until
    /// the selected model is ready. See docs/superpowers/specs/2026-07-08-*.md.
    var transcriberModel: TranscriberModel {
        didSet { UserDefaults.standard.set(transcriberModel.rawValue, forKey: "transcriberModel") }
    }
```

In `init()` (after the `transcriptionLanguage` line ~116):

```swift
        self.transcriberModel = TranscriberModel.from(persisted: defaults.string(forKey: "transcriberModel"))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter TranscriberModelTests`
Expected: 4 tests PASS. Then `swift build` — no errors.

- [ ] **Step 6: Commit**

```bash
git add Tome/Sources/Tome/Transcription/TranscriberModel.swift Tome/Sources/Tome/Settings/AppSettings.swift Tome/Tests/TomeTests/TranscriberModelTests.swift
git commit -m "feat: TranscriberModel enum + persisted transcriberModel setting"
```

---

### Task 2: `ASRBackend` protocol + `ParakeetBackend` extraction

**Files:**
- Create: `Tome/Sources/Tome/Transcription/ASRBackend.swift`
- Create: `Tome/Sources/Tome/Transcription/ParakeetBackend.swift`
- Test: none (behavior-preserving extraction of SDK calls; exercised by Task 3's coordinator tests via FakeBackend and by the existing app path).

**Interfaces:**
- Consumes: `TranscriberModel` (Task 1); FluidAudio `AsrModels.downloadAndLoad(version:progressHandler:)`, `AsrModels.modelsExist(at:version:)`, `AsrModels.defaultCacheDirectory(for:)`, `AsrManager`, `TdtDecoderState.make()`, `Language`, `ASRResult`, `DownloadUtils.DownloadProgress`.
- Produces:
  ```swift
  enum PrepareEvent: Sendable { case downloading(progress: Double?); case loading }
  protocol ASRBackend: AnyObject, Sendable {
      var model: TranscriberModel { get }
      static func isInstalled() -> Bool
      func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws
      func transcribe(samples: [Float], language: Language) async throws -> ASRResult
      func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult
      func unload() async
  }
  final actor ParakeetBackend: ASRBackend
  ```

- [ ] **Step 1: Write the protocol**

`Tome/Sources/Tome/Transcription/ASRBackend.swift`:

```swift
@preconcurrency import AVFoundation
import FluidAudio

/// Phase notifications from `ASRBackend.prepare`. The provisioner renders
/// `.downloading` with a percentage (nil = indeterminate) and `.loading` as
/// an indeterminate spinner — a bare (Double) -> Void callback couldn't
/// signal the download→load transition.
enum PrepareEvent: Sendable {
    case downloading(progress: Double?)
    case loading
}

/// One loadable ASR model. Conformances are actors: they own mutable SDK
/// handles (AsrManager / WhisperKit) that must be serialized.
///
/// AnyObject is load-bearing: ASRCoordinator tracks in-flight transcribe
/// calls per backend by ObjectIdentifier so a retired backend is only
/// unloaded after its last in-flight call returns (Swift actors are
/// reentrant — a swap can land while a transcribe is suspended mid-call).
protocol ASRBackend: AnyObject, Sendable {
    var model: TranscriberModel { get }
    /// True if everything needed for an offline load is on disk. For Whisper
    /// this includes BOTH the model folder AND the cached tokenizer.json.
    static func isInstalled() -> Bool
    /// Download (if needed) and load into memory. Emits `.loading`
    /// immediately when already installed.
    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws
    func transcribe(samples: [Float], language: Language) async throws -> ASRResult
    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult
    /// Release model memory. Called by ASRCoordinator only after the
    /// backend's last in-flight transcribe call has completed.
    func unload() async
}
```

- [ ] **Step 2: Write ParakeetBackend**

`Tome/Sources/Tome/Transcription/ParakeetBackend.swift` — the FluidAudio code currently inside `ASRCoordinator.initialize()`/`transcribe`, moved verbatim where possible:

```swift
@preconcurrency import AVFoundation
import FluidAudio

/// Parakeet-TDT v3 via FluidAudio.
///
/// Fresh `TdtDecoderState` per call is deliberate: FluidAudio 0.14 removed
/// AsrManager's internal decoder state and requires the caller to thread
/// `decoderState: inout TdtDecoderState` through every transcribe call. Each
/// call gets a fresh state, matching FluidAudio 0.7.9's behavior where
/// `transcribe()` auto-reset decoder state after every call — Tome's
/// StreamingTranscriber hands over one VAD-bounded segment at a time, so
/// cross-call state carry-over would mean the LSTM/lastToken from a previous
/// utterance primes the decoder for an unrelated next utterance (Parakeet v3
/// is sensitive enough that this collapses output to "."/blank).
final actor ParakeetBackend: ASRBackend {
    nonisolated let model: TranscriberModel = .parakeetTDTv3
    private var asrManager: AsrManager?

    static func isInstalled() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws {
        guard asrManager == nil else { return }
        if Self.isInstalled() { onEvent(.loading) }
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress in
            switch progress.phase {
            case .listing: onEvent(.downloading(progress: nil))
            case .downloading: onEvent(.downloading(progress: progress.fractionCompleted))
            case .compiling: onEvent(.loading)
            }
        })
        onEvent(.loading)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    func transcribe(samples: [Float], language: Language) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(samples, decoderState: &state, language: language)
    }

    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult {
        guard let asrManager else { throw ASRCoordinatorError.notInitialized }
        var state = TdtDecoderState.make()
        return try await asrManager.transcribe(buffer, decoderState: &state, language: language)
    }

    func unload() async {
        await asrManager?.cleanup()
        asrManager = nil
    }
}
```

- [ ] **Step 3: Build**

Run: `cd /Users/nic/programming/tome/Tome && swift build`
Expected: SUCCESS (nothing references the new files yet). If `progress.phase`/`fractionCompleted` names mismatch, check `.build/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:127-153` (`DownloadProgress.fractionCompleted: Double`, `DownloadPhase` cases `.listing`, `.downloading(completedFiles:totalFiles:)`, `.compiling(modelName:)`).

- [ ] **Step 4: Commit**

```bash
git add Tome/Sources/Tome/Transcription/ASRBackend.swift Tome/Sources/Tome/Transcription/ParakeetBackend.swift
git commit -m "feat: ASRBackend protocol + ParakeetBackend extraction of FluidAudio path"
```

---

### Task 3: `ASRCoordinator` refactor — install/unload discipline

**Files:**
- Modify: `Tome/Sources/Tome/Transcription/ASRCoordinator.swift` (whole file, currently 55 lines)
- Create: `Tome/Tests/TomeTests/FakeBackend.swift`
- Test: `Tome/Tests/TomeTests/ASRCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ASRBackend`, `PrepareEvent` (Task 2).
- Produces (coordinator public surface — `transcribe(samples:source:)` / `transcribe(buffer:source:)` / `setLanguage(_:)` unchanged so StreamingTranscriber/SegmentReTranscriber need zero edits):
  ```swift
  actor ASRCoordinator {
      var isReady: Bool { get }                    // activeBackend != nil
      var activeModel: TranscriberModel? { get }   // activeBackend?.model
      func install(backend: any ASRBackend) async  // swap + deferred unload
      func setLanguage(_ language: Language)
      func transcribe(samples: [Float], source: AudioSource) async throws -> ASRResult
      func transcribe(buffer: AVAudioPCMBuffer, source: AudioSource) async throws -> ASRResult
  }
  ```
  `initialize()` and `isInitialized` are **deleted** (callers repointed in Task 6).
- Produces for tests: `FakeBackend` (see Step 1).

- [ ] **Step 1: Write FakeBackend**

`Tome/Tests/TomeTests/FakeBackend.swift`:

```swift
@preconcurrency import AVFoundation
import FluidAudio
@testable import Tome

/// Scriptable ASRBackend for state-machine tests — no real models, no network.
/// `prepare` behavior is driven by `PrepareScript`; `transcribe` can be made to
/// hang until released, to exercise the coordinator's deferred-unload path.
final actor FakeBackend: ASRBackend {
    enum PrepareScript: Sendable {
        /// Emit .downloading ticks then .loading, then succeed.
        case succeed(ticks: Int)
        /// Emit one .downloading tick then throw.
        case fail(message: String)
        /// Suspend until cancelled (or forever). Respects Task cancellation
        /// only when `cooperative` — an uncooperative hang models SDK calls
        /// that never check cancellation.
        case hang(cooperative: Bool)
        /// Suspend until `releasePrepare()` is called, then succeed —
        /// models a download that completes AFTER the user re-selected
        /// (late-success generation-guard tests).
        case succeedWhenReleased
        /// Suspend until `releasePrepare()` is called, then throw.
        case failWhenReleased(message: String)
    }

    struct FakeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated let model: TranscriberModel
    private let script: PrepareScript
    private(set) var prepareCalls = 0
    private(set) var unloadCalls = 0
    private var prepareGate: CheckedContinuation<Void, Never>?
    private var transcribeGate: CheckedContinuation<Void, Never>?
    private(set) var transcribesStarted = 0
    private(set) var transcribesFinished = 0
    /// When true, transcribe suspends until releaseTranscribe().
    var hangTranscribe = false

    init(model: TranscriberModel, script: PrepareScript = .succeed(ticks: 2)) {
        self.model = model
        self.script = script
    }

    static func isInstalled() -> Bool { false }

    func setHangTranscribe(_ hang: Bool) { hangTranscribe = hang }

    func releasePrepare() {
        prepareGate?.resume()
        prepareGate = nil
    }

    func releaseTranscribe() {
        transcribeGate?.resume()
        transcribeGate = nil
    }

    func prepare(onEvent: @Sendable @escaping (PrepareEvent) -> Void) async throws {
        prepareCalls += 1
        switch script {
        case .succeed(let ticks):
            for i in 0..<ticks {
                try Task.checkCancellation()
                onEvent(.downloading(progress: Double(i) / Double(max(ticks, 1))))
                await Task.yield()
            }
            onEvent(.loading)
        case .fail(let message):
            onEvent(.downloading(progress: 0))
            throw FakeError(message: message)
        case .hang(let cooperative):
            onEvent(.downloading(progress: nil))
            if cooperative {
                // Sleep respects cancellation.
                try await Task.sleep(for: .seconds(3600))
            } else {
                await withCheckedContinuation { prepareGate = $0 }
            }
        case .succeedWhenReleased:
            onEvent(.downloading(progress: nil))
            await withCheckedContinuation { prepareGate = $0 }
            onEvent(.loading)
        case .failWhenReleased(let message):
            onEvent(.downloading(progress: nil))
            await withCheckedContinuation { prepareGate = $0 }
            throw FakeError(message: message)
        }
    }

    func transcribe(samples: [Float], language: Language) async throws -> ASRResult {
        transcribesStarted += 1
        if hangTranscribe {
            await withCheckedContinuation { transcribeGate = $0 }
        }
        transcribesFinished += 1
        return ASRResult(
            text: "fake:\(model.rawValue)", confidence: 1.0,
            duration: Double(samples.count) / 16_000.0, processingTime: 0.001
        )
    }

    func transcribe(buffer: AVAudioPCMBuffer, language: Language) async throws -> ASRResult {
        try await transcribe(samples: [], language: language)
    }

    func unload() async {
        unloadCalls += 1
    }
}
```

- [ ] **Step 2: Write the failing coordinator tests**

`Tome/Tests/TomeTests/ASRCoordinatorTests.swift`:

```swift
import Testing
@testable import Tome

@Suite struct ASRCoordinatorTests {
    @Test func transcribeWithoutBackendThrowsNotInitialized() async {
        let coordinator = ASRCoordinator()
        // Type form: ASRCoordinatorError isn't Equatable (and needn't be).
        await #expect(throws: ASRCoordinatorError.self) {
            _ = try await coordinator.transcribe(samples: [0.0], source: .microphone)
        }
    }

    @Test func installMakesReadyAndRoutesTranscribes() async throws {
        let coordinator = ASRCoordinator()
        let backend = FakeBackend(model: .parakeetTDTv3)
        await coordinator.install(backend: backend)
        #expect(await coordinator.isReady)
        #expect(await coordinator.activeModel == .parakeetTDTv3)
        let result = try await coordinator.transcribe(samples: [0.0], source: .microphone)
        #expect(result.text == "fake:parakeet-tdt-v3")
    }

    @Test func swapWithNoInFlightCallsUnloadsOldImmediately() async throws {
        let coordinator = ASRCoordinator()
        let old = FakeBackend(model: .parakeetTDTv3)
        let new = FakeBackend(model: .whisperLargeV3Turbo)
        await coordinator.install(backend: old)
        await coordinator.install(backend: new)
        #expect(await old.unloadCalls == 1)
        #expect(await coordinator.activeModel == .whisperLargeV3Turbo)
    }

    /// The unload-under-use hazard from the spec: a swap landing while a
    /// transcribe is suspended mid-call must not unload the old backend
    /// until that call returns.
    @Test func unloadIsDeferredUntilInFlightCallCompletes() async throws {
        let coordinator = ASRCoordinator()
        let old = FakeBackend(model: .parakeetTDTv3)
        let new = FakeBackend(model: .whisperLargeV3Turbo)
        await coordinator.install(backend: old)
        await old.setHangTranscribe(true)

        let inFlight = Task {
            try await coordinator.transcribe(samples: [0.0], source: .microphone)
        }
        // Wait until the call is actually suspended inside the old backend.
        for _ in 0..<100 {
            if await old.transcribesStarted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await old.transcribesStarted == 1)

        await coordinator.install(backend: new)
        // Swap done, old call still hung: no unload yet.
        #expect(await old.unloadCalls == 0)
        // New calls route to the new backend while the old call is hung.
        let routed = try await coordinator.transcribe(samples: [0.0], source: .microphone)
        #expect(routed.text == "fake:whisper-large-v3-turbo")

        await old.releaseTranscribe()
        let result = try await inFlight.value
        #expect(result.text == "fake:parakeet-tdt-v3")   // completed on OLD backend
        for _ in 0..<100 {
            if await old.unloadCalls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await old.unloadCalls == 1)              // unloaded only after drain
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter ASRCoordinatorTests`
Expected: compile FAILURE — `ASRCoordinator` has no `install`/`isReady`/`activeModel`.

- [ ] **Step 4: Rewrite ASRCoordinator**

Replace `Tome/Sources/Tome/Transcription/ASRCoordinator.swift` with the file below, verbatim — it IS the complete file. (The old header's fresh-decoder-state rationale moved into ParakeetBackend's header in Task 2, where the decoder code now lives.)

```swift
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
    func install(backend: any ASRBackend) async {
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
```

- [ ] **Step 5: Stub the two orphaned `initialize()` call sites so the target compiles**

`swift build` will now fail at `TranscriptionEngine.swift:115` and `Recovery.swift:108` (both call the deleted `initialize()`). Task 6 rewires them properly; for now make the minimal truthful substitution at both sites:

In `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (line ~115), replace `try await asrCoordinator.initialize()` with:

```swift
            guard await asrCoordinator.isReady else { throw ASRCoordinatorError.notInitialized }
```

In `Tome/Sources/Tome/Recovery/Recovery.swift` (line ~108), replace `try await asr.initialize()` with:

```swift
        guard await asr.isReady else { throw RecoveryError.modelNotReady }
```

and add the case to `RecoveryError` (line ~20) with its description:

```swift
    case modelNotReady
```

and in its `errorDescription` switch:

```swift
        case .modelNotReady:
            return "Transcription model not ready — check Settings ▸ Transcription"
```

- [ ] **Step 6: Run tests + build**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter ASRCoordinatorTests && swift build`
Expected: 4 tests PASS; build SUCCESS.

- [ ] **Step 7: Run the full suite (regression check)**

Run: `cd /Users/nic/programming/tome/Tome && swift test`
Expected: all suites PASS (existing tests construct `ASRCoordinator()` bare and never call `initialize()` — verified: only PostProcessingQueue/Job tests use it, and those exercise failure paths that don't touch ASR).

- [ ] **Step 8: Commit**

```bash
git add Tome/Sources/Tome/Transcription/ASRCoordinator.swift Tome/Tests/TomeTests/FakeBackend.swift Tome/Tests/TomeTests/ASRCoordinatorTests.swift Tome/Sources/Tome/Transcription/TranscriptionEngine.swift Tome/Sources/Tome/Recovery/Recovery.swift
git commit -m "feat: ASRCoordinator serves installable backends with drain-then-unload discipline"
```

---

### Task 4: `ModelProvisioner` state machine

**Files:**
- Create: `Tome/Sources/Tome/Transcription/ModelProvisioner.swift`
- Test: `Tome/Tests/TomeTests/ModelProvisionerTests.swift`

**Interfaces:**
- Consumes: `ASRCoordinator.install(backend:)`, `isReady`, `activeModel` (Task 3); `ASRBackend`/`PrepareEvent` (Task 2); `TranscriberModel` (Task 1); `FakeBackend` (Task 3, tests only).
- Produces:
  ```swift
  @MainActor @Observable final class ModelProvisioner {
      enum Activity: Equatable, Sendable { case none; case downloading(TranscriberModel, progress: Double?); case loading(TranscriberModel) }
      struct Failure: Equatable, Sendable { let model: TranscriberModel; let message: String }
      private(set) var servingModel: TranscriberModel?
      private(set) var activity: Activity
      private(set) var lastFailure: Failure?
      var canStartRecording: Bool { get }
      var lastGoodModel: TranscriberModel? { get }
      init(coordinator: ASRCoordinator,
           selection: @escaping @MainActor () -> TranscriberModel,
           setSelection: @escaping @MainActor (TranscriberModel) -> Void,
           makeBackend: @escaping @MainActor (TranscriberModel) -> any ASRBackend,
           defaults: UserDefaults = .standard)
      func provision(_ model: TranscriberModel)
      func retry()
      func awaitSettled() async
  }
  ```

Read spec §4 before implementing — every rule below is normative there (generation guard, F1/F2/F3 ladder, flip-back, lastFailure clearing).

- [ ] **Step 1: Write the failing tests**

`Tome/Tests/TomeTests/ModelProvisionerTests.swift`. The harness stands in for AppSettings (selection closures over a local var) and the backend factory (scripted FakeBackends, a fresh one per factory call so retries get a clean instance):

```swift
import Foundation
import Testing
@testable import Tome

/// Test double for the app wiring around ModelProvisioner. Unlike the app
/// (AppSettings.didSet → ContentView.onChange → provision), setSelection here
/// does NOT echo back into provision — the machine must not rely on that echo.
/// `echoSelectionWrites` opts in to simulate the real wiring.
@MainActor
final class ProvisionerHarness {
    var selectionValue: TranscriberModel = .parakeetTDTv3
    var setSelectionCalls: [TranscriberModel] = []
    var echoSelectionWrites = false
    let coordinator = ASRCoordinator()
    let defaults: UserDefaults
    private let suiteName: String
    var scriptQueues: [TranscriberModel: [FakeBackend.PrepareScript]]
    private(set) var createdBackends: [FakeBackend] = []
    private(set) var provisioner: ModelProvisioner!

    /// Last backend the factory created for a model.
    func lastBackend(for model: TranscriberModel) -> FakeBackend? {
        createdBackends.last { $0.model == model }
    }

    init(scripts: [TranscriberModel: [FakeBackend.PrepareScript]] = [:]) {
        suiteName = "tome-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        scriptQueues = scripts
        provisioner = ModelProvisioner(
            coordinator: coordinator,
            selection: { [unowned self] in selectionValue },
            setSelection: { [unowned self] model in
                selectionValue = model
                setSelectionCalls.append(model)
                // Mirror AppSettings.didSet: selection writes persist. Lets
                // tests assert the revert landed in defaults (spec §9 test 2).
                defaults.set(model.rawValue, forKey: "transcriberModel")
                // The echo must be ASYNC like SwiftUI's onChange (next
                // runloop) — a synchronous echo would re-enter provision()
                // mid-failure-handling, which the real wiring can never do.
                if echoSelectionWrites {
                    Task { @MainActor [unowned self] in provisioner.provision(model) }
                }
            },
            makeBackend: { [unowned self] model in
                var queue = scriptQueues[model] ?? []
                let script = queue.isEmpty ? .succeed(ticks: 1) : queue.removeFirst()
                scriptQueues[model] = queue
                let backend = FakeBackend(model: model, script: script)
                createdBackends.append(backend)
                return backend
            },
            defaults: defaults
        )
    }

    func settle() async {
        await provisioner.awaitSettled()
    }
}

@Suite @MainActor struct ModelProvisionerTests {
    // Spec §9 test 1
    @Test func happyPathSwapAlignsSelectionServingAndLastGood() async throws {
        let h = ProvisionerHarness()
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        #expect(h.provisioner.servingModel == .parakeetTDTv3)

        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()
        #expect(h.provisioner.servingModel == .whisperLargeV3Turbo)
        #expect(h.provisioner.lastGoodModel == .whisperLargeV3Turbo)
        #expect(h.provisioner.canStartRecording)
        #expect(await h.coordinator.activeModel == .whisperLargeV3Turbo)
        // Old backend drained + unloaded (no in-flight calls here).
        #expect(await h.lastBackend(for: .parakeetTDTv3)?.unloadCalls == 1)
    }

    // Spec §9 test 2 — F1
    @Test func downloadFailureWithServingBackendRevertsSelection() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.fail(message: "offline")]])
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()

        h.selectionValue = .whisperLargeV3Turbo
        h.echoSelectionWrites = true   // real wiring active for the revert write
        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()

        #expect(h.setSelectionCalls == [.parakeetTDTv3])       // reverted via normal write
        #expect(h.selectionValue == .parakeetTDTv3)
        // The revert went through the persisting path — survives relaunch.
        #expect(h.defaults.string(forKey: "transcriberModel") == "parakeet-tdt-v3")
        #expect(h.provisioner.lastFailure == .init(model: .whisperLargeV3Turbo, message: "offline"))
        #expect(h.provisioner.servingModel == .parakeetTDTv3)
        #expect(h.provisioner.canStartRecording)               // recording available again
        // The revert echo must NOT have re-provisioned Parakeet (no second backend).
        #expect(h.createdBackends.filter { $0.model == .parakeetTDTv3 }.count == 1)
    }

    // Spec §9 test 3 — F2 chain, lastFailure survives
    @Test func failureWithNothingServingFallsBackToLastGood() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.fail(message: "offline")]])
        // Simulate a prior run where Parakeet reached ready: persisted last-good,
        // but nothing resident (fresh relaunch mid-switch).
        h.defaults.set(TranscriberModel.parakeetTDTv3.rawValue, forKey: "lastGoodTranscriberModel")
        h.selectionValue = .whisperLargeV3Turbo
        h.echoSelectionWrites = true

        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()

        #expect(h.selectionValue == .parakeetTDTv3)            // F2 revert
        #expect(h.provisioner.servingModel == .parakeetTDTv3)  // ...and provisioned
        #expect(h.provisioner.canStartRecording)
        // The chained cycle and its success must NOT clear the failure.
        #expect(h.provisioner.lastFailure == .init(model: .whisperLargeV3Turbo, message: "offline"))
    }

    // Spec §9 test 3, second clause — the F2 chain TERMINATES when the
    // fallback also fails (the cell where revert recursion would hide).
    @Test func f2ChainEndsInF3WhenLastGoodAlsoFails() async throws {
        let h = ProvisionerHarness(scripts: [
            .whisperLargeV3Turbo: [.fail(message: "offline")],
            .parakeetTDTv3: [.fail(message: "also offline")],
        ])
        h.defaults.set(TranscriberModel.parakeetTDTv3.rawValue, forKey: "lastGoodTranscriberModel")
        h.selectionValue = .whisperLargeV3Turbo
        h.echoSelectionWrites = true

        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()

        #expect(h.provisioner.servingModel == nil)
        #expect(h.provisioner.activity == .none)
        #expect(!h.provisioner.canStartRecording)
        #expect(h.createdBackends.count == 2)                  // W, then P — no loop
        #expect(h.provisioner.lastFailure != nil)              // Retry affordance present
        #expect(h.selectionValue == .parakeetTDTv3)            // rests on the F2 target
    }

    // Spec §9 test 4 — F3 both flavors + retry re-enters despite unchanged selection
    @Test func failureWithNoFallbackRestsFailedAndRetryReenters() async throws {
        let h = ProvisionerHarness(scripts: [.parakeetTDTv3: [.fail(message: "disk full"), .succeed(ticks: 1)]])
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()

        #expect(h.provisioner.servingModel == nil)
        #expect(h.provisioner.lastFailure == .init(model: .parakeetTDTv3, message: "disk full"))
        #expect(!h.provisioner.canStartRecording)
        #expect(h.setSelectionCalls.isEmpty)                   // no revert target — selection stays

        h.provisioner.retry()                                  // selection value unchanged — direct call fires
        await h.settle()
        #expect(h.provisioner.servingModel == .parakeetTDTv3)
        #expect(h.provisioner.lastFailure == nil)
        #expect(h.provisioner.canStartRecording)
    }

    @Test func failureOfLastGoodItselfRestsFailed() async throws {
        let h = ProvisionerHarness(scripts: [.parakeetTDTv3: [.fail(message: "cache corrupt")]])
        h.defaults.set(TranscriberModel.parakeetTDTv3.rawValue, forKey: "lastGoodTranscriberModel")
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        // lastGood == failed model: F3, not an F2 self-loop.
        #expect(h.provisioner.lastFailure?.model == .parakeetTDTv3)
        #expect(h.provisioner.servingModel == nil)
        #expect(h.createdBackends.count == 1)                  // exactly one attempt
    }

    // Spec §9 test 5 — cancel + stale-outcome guards
    @Test func reselectingCancelsAndLateFailureIsInert() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.failWhenReleased(message: "late boom")]])
        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        // Mid-download, user flips to Parakeet.
        h.selectionValue = .parakeetTDTv3
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        #expect(h.provisioner.servingModel == .parakeetTDTv3)

        // Now the superseded Whisper cycle fails — must not revert or record failure.
        await h.lastBackend(for: .whisperLargeV3Turbo)?.releasePrepare()
        try await Task.sleep(for: .milliseconds(100))   // let the stale outcome land
        #expect(h.provisioner.lastFailure == nil)
        #expect(h.selectionValue == .parakeetTDTv3)
        #expect(h.setSelectionCalls.isEmpty)
    }

    @Test func lateSuccessOfSupersededCycleDoesNotInstall() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.succeedWhenReleased]])
        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        h.selectionValue = .parakeetTDTv3
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()

        await h.lastBackend(for: .whisperLargeV3Turbo)?.releasePrepare()
        try await Task.sleep(for: .milliseconds(100))   // let the stale outcome land
        #expect(await h.coordinator.activeModel == .parakeetTDTv3)   // wrong backend NOT installed
        #expect(h.provisioner.servingModel == .parakeetTDTv3)
        #expect(h.provisioner.lastGoodModel == .parakeetTDTv3)       // last-good not clobbered
    }

    // Spec §9 test 6
    @Test func selectingAlreadyServingModelIsNoOp() async throws {
        let h = ProvisionerHarness()
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        h.provisioner.provision(.parakeetTDTv3)
        #expect(h.createdBackends.count == 1)                  // factory not called again
        #expect(h.provisioner.activity == .none)
    }

    // Spec §9 test 8
    @Test func lastGoodAbsentUntilFirstReadyAndUnknownRawTreatedAsAbsent() async throws {
        let h = ProvisionerHarness()
        #expect(h.provisioner.lastGoodModel == nil)
        h.defaults.set("some-future-model", forKey: "lastGoodTranscriberModel")
        #expect(h.provisioner.lastGoodModel == nil)            // unknown raw ⇒ absent, NOT Parakeet
        h.defaults.removeObject(forKey: "lastGoodTranscriberModel")
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        #expect(h.provisioner.lastGoodModel == .parakeetTDTv3)
        #expect(h.defaults.string(forKey: "lastGoodTranscriberModel") == "parakeet-tdt-v3")
    }

    // Spec §9 test 9 — flip back to serving model mid-download
    @Test func flipBackToServingModelCancelsWithoutReprovision() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.hang(cooperative: true)]])
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()

        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        #expect(h.provisioner.activity != .none)               // download in flight
        #expect(!h.provisioner.canStartRecording)              // gated during swap

        h.selectionValue = .parakeetTDTv3
        h.provisioner.provision(.parakeetTDTv3)                // flip back
        #expect(h.provisioner.activity == .none)               // immediate, no cycle
        #expect(h.provisioner.canStartRecording)
        #expect(h.createdBackends.filter { $0.model == .parakeetTDTv3 }.count == 1)
    }

    // Spec §9 test 10 — retry lockstep after F1
    @Test func retryAfterRevertRealignsSelectionServingAndLastGood() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.fail(message: "offline"), .succeed(ticks: 1)]])
        h.echoSelectionWrites = true
        h.provisioner.provision(.parakeetTDTv3)
        await h.settle()
        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()
        #expect(h.selectionValue == .parakeetTDTv3)            // F1 revert happened

        h.provisioner.retry()
        await h.settle()
        #expect(h.selectionValue == .whisperLargeV3Turbo)
        #expect(h.provisioner.servingModel == .whisperLargeV3Turbo)
        #expect(h.provisioner.lastGoodModel == .whisperLargeV3Turbo)
        #expect(h.provisioner.lastFailure == nil)
        #expect(await h.coordinator.activeModel == .whisperLargeV3Turbo)
    }

    /// awaitSettled must ride through an F2 chain (fail → fall back → last-good
    /// ready), not wake in the momentary activity==.none gap between them.
    @Test func awaitSettledSpansTheF2Chain() async throws {
        let h = ProvisionerHarness(scripts: [.whisperLargeV3Turbo: [.fail(message: "offline")]])
        h.defaults.set(TranscriberModel.parakeetTDTv3.rawValue, forKey: "lastGoodTranscriberModel")
        h.selectionValue = .whisperLargeV3Turbo
        h.provisioner.provision(.whisperLargeV3Turbo)
        await h.settle()
        // If settle returned at the F2 gap, serving would still be nil here.
        #expect(h.provisioner.servingModel == .parakeetTDTv3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter ModelProvisionerTests`
Expected: compile FAILURE — `cannot find 'ModelProvisioner' in scope`.

- [ ] **Step 3: Implement ModelProvisioner**

`Tome/Sources/Tome/Transcription/ModelProvisioner.swift`:

```swift
import Foundation
import Observation

/// The ONLY component that downloads/loads ASR models and the only writer of
/// provisioning state. Drives the state machine in spec §4
/// (docs/superpowers/specs/2026-07-08-whisper-v3-turbo-model-option-design.md):
/// `servingModel` answers "can I record, and with what?"; `activity` +
/// `lastFailure` answer "what happened to the model I picked?".
///
/// Selection plumbing is injected as closures so tests can drive the machine
/// without AppSettings/UserDefaults.standard. In the app: `selection` reads
/// `settings.transcriberModel`, `setSelection` writes it (didSet persists;
/// the resulting onChange → provision echo no-ops via the guards here).
@MainActor
@Observable
final class ModelProvisioner {
    enum Activity: Equatable, Sendable {
        case none
        case downloading(TranscriberModel, progress: Double?)
        case loading(TranscriberModel)

        var provisioningModel: TranscriberModel? {
            switch self {
            case .none: nil
            case .downloading(let model, _), .loading(let model): model
            }
        }
    }

    struct Failure: Equatable, Sendable {
        let model: TranscriberModel
        let message: String
    }

    /// Model of the backend installed in the coordinator; nil until the first
    /// successful install (fresh install, or relaunch before provisioning lands).
    private(set) var servingModel: TranscriberModel?
    private(set) var activity: Activity = .none
    /// Most recent provisioning failure. Cleared when a user-initiated cycle
    /// starts and on its success; an F2-chained fallback cycle deliberately
    /// leaves it intact so Settings can show why the selection reverted.
    private(set) var lastFailure: Failure?

    var canStartRecording: Bool {
        activity == .none && servingModel != nil && servingModel == selection()
    }

    /// Most recent model that reached ready, persisted across launches.
    /// Absent (nil) until some model first succeeds — an unknown raw value is
    /// treated as absent, NOT defaulted, or a fresh install would be
    /// indistinguishable from "Parakeet worked before" (spec §1).
    var lastGoodModel: TranscriberModel? {
        defaults.string(forKey: Self.lastGoodKey).flatMap(TranscriberModel.init(rawValue:))
    }

    static let lastGoodKey = "lastGoodTranscriberModel"

    private let coordinator: ASRCoordinator
    private let selection: @MainActor () -> TranscriberModel
    private let setSelection: @MainActor (TranscriberModel) -> Void
    private let makeBackend: @MainActor (TranscriberModel) -> any ASRBackend
    private let defaults: UserDefaults
    /// Monotonic token identifying the current provisioning cycle. Outcomes
    /// from a superseded cycle (late failure after cancel, late success) are
    /// dropped — cancellation is cooperative and SDK calls may not observe it.
    private var generation = 0
    private var currentTask: Task<Void, Never>?

    init(
        coordinator: ASRCoordinator,
        selection: @escaping @MainActor () -> TranscriberModel,
        setSelection: @escaping @MainActor (TranscriberModel) -> Void,
        makeBackend: @escaping @MainActor (TranscriberModel) -> any ASRBackend,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.selection = selection
        self.setSelection = setSelection
        self.makeBackend = makeBackend
        self.defaults = defaults
    }

    func provision(_ model: TranscriberModel) {
        provision(model, clearingFailure: true)
    }

    /// Re-attempt the failed model. Writes the selection AND calls provision
    /// directly — in F3 the selection already is the failed model, and an
    /// unchanged-value write fires no onChange, so a write-only retry would
    /// be inert in the one state it exists for.
    func retry() {
        guard let failed = lastFailure?.model else { return }
        setSelection(failed)
        provision(failed)
    }

    /// Await a resting state (activity == .none with failure handling —
    /// including any chained F2 fallback — complete). Failure handling never
    /// suspends between clearing activity and starting an F2 chain, so a
    /// poller cannot observe that gap.
    func awaitSettled() async {
        while activity != .none {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func provision(_ model: TranscriberModel, clearingFailure: Bool) {
        if model == servingModel {
            if activity != .none {
                // Flip BACK to the serving model mid-swap: the serving backend
                // is still installed — cancel the swap, nothing to load.
                generation += 1
                currentTask?.cancel()
                currentTask = nil
                activity = .none
            }
            return
        }
        // Already provisioning this model (e.g. the onChange echo right after
        // retry()'s direct call) — let the in-flight cycle finish.
        if activity.provisioningModel == model { return }

        generation += 1
        let gen = generation
        currentTask?.cancel()
        if clearingFailure { lastFailure = nil }
        activity = .downloading(model, progress: nil)
        let backend = makeBackend(model)
        currentTask = Task { [weak self] in
            await self?.runCycle(model: model, backend: backend, generation: gen, clearingFailure: clearingFailure)
        }
    }

    private func runCycle(
        model: TranscriberModel,
        backend: any ASRBackend,
        generation gen: Int,
        clearingFailure: Bool
    ) async {
        do {
            try await backend.prepare { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    switch event {
                    case .downloading(let progress): self.activity = .downloading(model, progress: progress)
                    case .loading: self.activity = .loading(model)
                    }
                }
            }
            guard generation == gen else {
                // Superseded while preparing: never installed, safe to unload.
                await backend.unload()
                return
            }
            await coordinator.install(backend: backend)
            guard generation == gen else {
                // Superseded during install: the newer cycle's install will
                // retire this backend; its state writes own the machine now.
                return
            }
            servingModel = model
            defaults.set(model.rawValue, forKey: Self.lastGoodKey)
            if clearingFailure { lastFailure = nil }
            activity = .none
        } catch is CancellationError {
            return
        } catch {
            guard generation == gen else { return }   // stale failure: inert
            lastFailure = Failure(model: model, message: error.localizedDescription)
            // Failure ladder (spec §4 F1/F2/F3). No suspension between these
            // mutations — awaitSettled pollers can't observe a half-state.
            if let serving = servingModel {
                // F1: something else is serving (≠ model, guaranteed by the
                // flip-back rule). Revert the selection through the normal
                // write; the onChange echo no-ops via the servingModel guard.
                activity = .none
                setSelection(serving)
            } else if let lastGood = lastGoodModel, lastGood != model {
                // F2: nothing resident (fresh relaunch) — fall back to
                // last-good and provision it, WITHOUT clearing the failure.
                setSelection(lastGood)
                activity = .none
                provision(lastGood, clearingFailure: false)
            } else {
                // F3: no fallback. Retry is the recovery path; recording
                // stays gated (nothing could transcribe anyway).
                activity = .none
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter ModelProvisionerTests`
Expected: 13 tests PASS. Flakiness note: these tests are timing-sensitive by nature (Task scheduling); if one flakes, prefer widening a poll loop over sleeping longer.

- [ ] **Step 5: Full suite**

Run: `cd /Users/nic/programming/tome/Tome && swift test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Tome/Sources/Tome/Transcription/ModelProvisioner.swift Tome/Tests/TomeTests/ModelProvisionerTests.swift
git commit -m "feat: ModelProvisioner — generation-guarded provisioning state machine with F1/F2/F3 failure ladder"
```

---

### Task 5: `WhisperBackend`

**Files:**
- Create: `Tome/Sources/Tome/Transcription/WhisperBackend.swift`
- Modify: `Tome/Sources/Tome/Transcription/TranscriberModel.swift` (add `isInstalled` / `approxDownloadSize` extension at end)
- Test: `Tome/Tests/TomeTests/WhisperBackendTests.swift`

**Interfaces:**
- Consumes: `ASRBackend`/`PrepareEvent` (Task 2); WhisperKit (`WhisperKitConfig`, `WhisperKit.download(variant:downloadBase:progressCallback:)`, `WhisperKit.recommendedModels()`, `DecodingOptions`); FluidAudio's `ASRResult` (public memberwise init), `Language`.
- Produces: `final actor WhisperBackend: ASRBackend`; `WhisperBackend.resolveVariant(supported:) -> String`; `TranscriberModel.isInstalled: Bool`, `TranscriberModel.approxDownloadSize: String`.

**Pinned-SDK facts (verified against `.build/checkouts/argmax-oss-swift`):**
- OpenAI Large v3 Turbo = the `openai_whisper-large-v3-v20240930*` family. **`openai_whisper-large-v3_turbo` is a different model** (large-v3 + WhisperKit compression) — never use it.
- Device support (`Models.swift:1465` fallback config): M2/M3/M4 Macs support and default to full-precision `openai_whisper-large-v3-v20240930` (~1.5 GB); M1-class Macs support only `openai_whisper-large-v3-v20240930_626MB` (~0.6 GB).
- `WhisperKit.download` returns the variant folder URL; layout under a custom base is `downloadBase/models/argmaxinc/whisperkit-coreml/<variant>/`. `progressCallback` is `@Sendable (Progress) -> Void`.
- `WhisperKitConfig(model:downloadBase:modelFolder:load:download:)` with `modelFolder` set skips all model downloads; `tokenizerFolder` nil falls back to `downloadBase`, so the tokenizer lands at `downloadBase/models/openai/whisper-large-v3/tokenizer.json` (fetched over the network on first load if missing — which is why `isInstalled()` checks it).
- The model folder must contain `MelSpectrogram`, `AudioEncoder`, `TextDecoder` as `.mlmodelc` or `.mlpackage`.

- [ ] **Step 1: Write the failing tests** (pure logic only — no downloads)

`Tome/Tests/TomeTests/WhisperBackendTests.swift`:

```swift
import Foundation
import Testing
@testable import Tome

@Suite struct WhisperBackendTests {
    @Test func resolveVariantPrefersFullPrecisionWhenSupported() {
        let m2Supported = ["openai_whisper-large-v3-v20240930", "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-tiny"]
        #expect(WhisperBackend.resolveVariant(supported: m2Supported) == "openai_whisper-large-v3-v20240930")
    }

    @Test func resolveVariantFallsBackToQuantizedOnM1() {
        let m1Supported = ["openai_whisper-large-v3-v20240930_626MB", "openai_whisper-tiny"]
        #expect(WhisperBackend.resolveVariant(supported: m1Supported) == "openai_whisper-large-v3-v20240930_626MB")
    }

    @Test func resolveVariantNeverPicksTheMisnamedTurboVariant() {
        // "openai_whisper-large-v3_turbo" is NOT Large v3 Turbo (spec §2).
        let trap = ["openai_whisper-large-v3_turbo", "openai_whisper-large-v3-v20240930_626MB"]
        #expect(WhisperBackend.resolveVariant(supported: trap) == "openai_whisper-large-v3-v20240930_626MB")
    }

    @Test func modelFolderLayoutMatchesHubApi() {
        let folder = WhisperBackend.modelFolder(variant: "openai_whisper-large-v3-v20240930")
        #expect(folder.path.hasSuffix("Tome/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"))
        #expect(WhisperBackend.tokenizerJSON.path.hasSuffix("Tome/WhisperKit/models/openai/whisper-large-v3/tokenizer.json"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter WhisperBackendTests`
Expected: compile FAILURE — `cannot find 'WhisperBackend' in scope`.

- [ ] **Step 3: Implement WhisperBackend**

`Tome/Sources/Tome/Transcription/WhisperBackend.swift`:

```swift
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
```

If `unloadModels()` is synchronous in the pinned revision, drop the `await` (compiler will say). If `WhisperKit.download`'s parameter order differs, match `.build/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/WhisperKit.swift:244`.

- [ ] **Step 4: Add the TranscriberModel convenience extension**

At the end of `Tome/Sources/Tome/Transcription/TranscriberModel.swift`:

```swift
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
```

- [ ] **Step 5: Run tests + build**

Run: `cd /Users/nic/programming/tome/Tome && swift test --filter WhisperBackendTests && swift build`
Expected: 4 tests PASS; build SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add Tome/Sources/Tome/Transcription/WhisperBackend.swift Tome/Sources/Tome/Transcription/TranscriberModel.swift Tome/Tests/TomeTests/WhisperBackendTests.swift
git commit -m "feat: WhisperBackend — large-v3-turbo via WhisperKit with device-resolved variant"
```

---

### Task 6: Rewire `TranscriptionEngine.start()` and `Recovery.run()`

**Files:**
- Modify: `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` (start() model block ~L111-133, "Transcribing" status ~L295)
- Modify: `Tome/Sources/Tome/Transcription/ASRCoordinator.swift` (add `LocalizedError` conformance at the bottom)
- Modify: `Tome/Sources/Tome/Recovery/Recovery.swift` (signature + readiness wait)
- Modify: `Tome/Sources/Tome/Views/ContentView.swift` (the two `Recovery.run` call sites, ~L832 and ~L978)
- Test: existing suites (regression only — the new behavior is provisioner-driven and covered by Task 4; Recovery has no test seam for provisioner injection and gets covered by the smoke pass).

**Interfaces:**
- Consumes: `ASRCoordinator.isReady` / `activeModel` (Task 3); `ModelProvisioner.awaitSettled()` (Task 4).
- Produces: `Recovery.run(wavURL:transcriptURL:asr:provisioner:clusterThreshold:numberOfSpeakers:exportVoiceprints:preserveYou:)` — the added `provisioner: ModelProvisioner` parameter is what Task 7's call sites pass.

- [ ] **Step 1: Engine — readiness check instead of model load**

In `TranscriptionEngine.start()`, replace the whole model-loading block (from `// 1. Load FluidAudio models` through the stub added in Task 3, ending just before `guard let vadManager`):

```swift
        // 1. Verify ASR readiness. Model download/load lives in
        //    ModelProvisioner; the UI gates recording on readiness, so this
        //    is a formality — but API starts and races land here too.
        do {
            guard await asrCoordinator.isReady else {
                throw ASRCoordinatorError.notInitialized
            }
            assetStatus = "Loading VAD model..."
            diagLog("[ENGINE-1b] loading VAD model...")
            let vad = try await VadManager()
            self.vadManager = vad

            assetStatus = "Models ready"
            diagLog("[ENGINE-2] models ready")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            endLiveActivity()
            return
        }
```

(The deleted strings `"Loading ASR model (~600MB first run)..."` and `"Initializing ASR..."` must not survive anywhere — `grep -rn "600MB\|Initializing ASR" Tome/Sources` returns nothing afterward.)

- [ ] **Step 2: Engine — model-parameterized Transcribing status**

At ~L295 replace `assetStatus = "Transcribing (Parakeet-TDT v3)"` with:

```swift
        let modelName = await asrCoordinator.activeModel?.displayName ?? "ASR"
        assetStatus = "Transcribing (\(modelName))"
```

The `Transcribing (` prefix is API-matched (`/health` does `contains("Transcribing")`) — keep it verbatim.

- [ ] **Step 3: Readable error for the not-ready case**

At the bottom of `ASRCoordinator.swift`, extend the error (the raw enum renders as an unhelpful "The operation couldn't be completed"):

```swift
extension ASRCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "Transcription model not ready — check Settings ▸ Transcription"
        }
    }
}
```

- [ ] **Step 4: Recovery waits for provisioning to settle**

In `Recovery.swift`, add the parameter (after `asr: ASRCoordinator`):

```swift
    static func run(
        wavURL: URL,
        transcriptURL: URL,
        asr: ASRCoordinator,
        provisioner: ModelProvisioner,
        clusterThreshold: Float,
        numberOfSpeakers: Int,
        exportVoiceprints: Bool = false,
        preserveYou: Bool = true
    ) async throws -> URL
```

and replace the Task 3 stub (`guard await asr.isReady else { throw RecoveryError.modelNotReady }`) with:

```swift
        // Launch-time orphan recovery can race the provisioner's launch kick —
        // wait for it to settle (including an F2 fallback chain) instead of
        // triggering a second model load. If nothing is installed after
        // settling (fresh install, download failed), recovery can't run;
        // orphans stay on disk for a later launch or File ▸ Recover.
        await provisioner.awaitSettled()
        guard await asr.isReady else { throw RecoveryError.modelNotReady }
```

- [ ] **Step 5: Update both ContentView call sites**

At ~L832 (`recoverOrphans`) and ~L978 (`recoverFromWAV`), add the argument after `asr: services.asrCoordinator`:

```swift
                    provisioner: services.modelProvisioner,
```

This won't compile until Task 7 adds `modelProvisioner` to AppServices — **do Tasks 6 and 7 in one working session** (Task 6 alone leaves the tree red; the Task 6 commit happens after Task 7's build passes if executing strictly sequentially, or fold both into one commit).

- [ ] **Step 6: Proceed to Task 7 before committing**

---

### Task 7: App wiring — `AppServices(settings:)`, launch kick, selection observer

**Files:**
- Modify: `Tome/Sources/Tome/App/AppServices.swift`
- Modify: `Tome/Sources/Tome/App/TomeApp.swift` (state construction L64-67)
- Modify: `Tome/Sources/Tome/Views/ContentView.swift` (boot task ~L151, onChange block ~L133, recovery flags)
- Test: existing suites (wiring is exercised by Task 12/13; AppServices has no test seam and none is added — YAGNI).

**Interfaces:**
- Consumes: `ModelProvisioner` (Task 4), `ParakeetBackend` (Task 2), `WhisperBackend` (Task 5), `AppSettings.transcriberModel` (Task 1).
- Produces: `AppServices.modelProvisioner: ModelProvisioner`; `AppServices.isRecovering: Bool`; `AppServices.init(settings: AppSettings)` (parameterless init removed).

- [ ] **Step 1: AppServices owns the provisioner**

In `AppServices.swift` add stored properties and replace `init()`:

```swift
    let modelProvisioner: ModelProvisioner

    /// True while orphan recovery or File ▸ Recover is re-transcribing.
    /// Settings uses it (with isRecording / isAnyJobRunning) to lock the
    /// model picker so a swap can't land mid-job.
    var isRecovering = false

    init(settings: AppSettings) {
        let asr = ASRCoordinator()
        self.asrCoordinator = asr
        self.postProcessingQueue = PostProcessingQueue(asr: asr)
        self.transcriptLogger = TranscriptLogger()
        self.sessionStore = SessionStore()
        self.modelProvisioner = ModelProvisioner(
            coordinator: asr,
            selection: { settings.transcriberModel },
            setSelection: { settings.transcriberModel = $0 },
            makeBackend: { model in
                switch model {
                case .parakeetTDTv3: ParakeetBackend()
                case .whisperLargeV3Turbo: WhisperBackend()
                }
            }
        )
    }
```

(`settings` captured strongly is fine: AppSettings never references AppServices, both are owned by TomeApp for the app's lifetime.)

- [ ] **Step 2: TomeApp connects them**

`AppSettings` and `AppServices` are currently independent `@State` initializers; property initializers can't reference each other, so give TomeApp an `init`:

```swift
    @State private var settings: AppSettings
    @State private var services: AppServices

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _services = State(initialValue: AppServices(settings: settings))
    }
```

(Leave `appDelegate`, `updaterController`, `apiServer` as they are.)

- [ ] **Step 3: ContentView — launch kick + selection observer**

In the boot `.task` (right after the `TranscriptionEngine` is constructed and `setLanguage` is pushed, ~L151) add:

```swift
            // Kick provisioning of the selected model before anything that
            // needs ASR (notably the orphan scan at the end of this task,
            // which awaits the provisioner settling).
            services.modelProvisioner.provision(settings.transcriberModel)
```

Next to the existing `.onChange(of: settings.transcriptionLanguage)` (~L133) add:

```swift
        .onChange(of: settings.transcriberModel) { _, model in
            services.modelProvisioner.provision(model)
        }
```

- [ ] **Step 4: ContentView — recovery flag**

In `recoverOrphans` (~L813), wrap the recovery loop:

```swift
        services.isRecovering = true
        defer { services.isRecovering = false }
```

In `recoverFromWAV` the placement is subtler: the function is synchronous, shows dialogs with early returns (the `.mic.wav` fork's cancel path ~L971), and does the actual work in a `Task { [preserveYou] in … }` spawned ~L975. Put BOTH statements as the **first two lines inside that Task closure**:

```swift
        Task { [preserveYou] in
            services.isRecovering = true
            defer { services.isRecovering = false }
            // ...existing Recovery.run work...
```

Not at the function top (the defer would fire when the function returns — immediately after spawning the Task, clearing the flag while recovery still runs) and not before the dialogs (a cancelled dialog would leave the flag stuck true, permanently locking the Settings picker). The dialogs themselves need no lock — no recovery is in flight yet.

- [ ] **Step 5: Build + full suite, then commit Tasks 6+7 together**

Run: `cd /Users/nic/programming/tome/Tome && swift build && swift test`
Expected: build SUCCESS, all tests PASS.

```bash
git add Tome/Sources/Tome/Transcription/TranscriptionEngine.swift Tome/Sources/Tome/Transcription/ASRCoordinator.swift Tome/Sources/Tome/Recovery/Recovery.swift Tome/Sources/Tome/App/AppServices.swift Tome/Sources/Tome/App/TomeApp.swift Tome/Sources/Tome/Views/ContentView.swift
git commit -m "feat: wire ModelProvisioner — launch kick, selection observer, engine/recovery readiness"
```

---

### Task 8: Main-screen gating (ControlBar + ContentView)

**Files:**
- Modify: `Tome/Sources/Tome/Views/ControlBar.swift` (add two inputs, gate buttons, render model status)
- Modify: `Tome/Sources/Tome/Views/ContentView.swift` (ControlBar instantiation ~L92-109, status/error computation, startSession guard ~L497)
- Test: none automated (SwiftUI view layer; covered by the smoke pass in Task 13). The gating LOGIC lives in `ModelProvisioner.canStartRecording`, already tested in Task 4.

**Interfaces:**
- Consumes: `ModelProvisioner.activity/servingModel/lastFailure/canStartRecording` (Task 4), `TranscriberModel.displayName` (Task 1).
- Produces: `ControlBar` gains `let modelStatus: String?` and `let canStartRecording: Bool`.

- [ ] **Step 1: ControlBar inputs + gating**

Add to `ControlBar`'s stored properties (after `statusMessage`/`errorMessage`, ~L29):

```swift
    /// Provisioning status ("DOWNLOADING MODEL… 42%") — rendered like
    /// statusMessage but sourced from ModelProvisioner, NOT assetStatus
    /// (the API string-matches assetStatus; provisioning must not leak in).
    let modelStatus: String?
    /// False while the selected model is downloading/loading/failed —
    /// disables both record buttons (and thereby their ⌘R/⌘⇧R shortcuts).
    let canStartRecording: Bool
```

In `body`, directly under the `statusMessage` row (~L60), add a model-status row:

```swift
            if let modelStatus {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.accent1)
                    Text(modelStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.fg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
```

Gate both record buttons: add to the Call Capture button and the Voice Memo button (after their `.keyboardShortcut` lines):

```swift
                    .disabled(!canStartRecording)
                    .opacity(canStartRecording ? 1 : 0.45)
```

- [ ] **Step 2: ContentView — status strings and wiring**

Add computed properties near `isRunning` (~L460):

```swift
    /// Main-screen provisioning banner (spec §7). Display-uppercased here;
    /// Settings shows the sentence-case versions.
    private var modelStatusText: String? {
        let provisioner = services.modelProvisioner
        switch provisioner.activity {
        case .downloading(_, let progress):
            if let progress { return "DOWNLOADING MODEL… \(Int(progress * 100))%" }
            return "DOWNLOADING MODEL…"
        case .loading:
            return "LOADING MODEL…"
        case .none:
            if provisioner.servingModel == nil, provisioner.lastFailure != nil {
                return "MODEL DOWNLOAD FAILED — retry in Settings ▸ Transcription"
            }
            if provisioner.servingModel != settings.transcriberModel {
                // Transient pre-kick / selection-write→onChange frames.
                return "LOADING MODEL…"
            }
            return nil
        }
    }

    /// Post-revert failure line (spec §7): shown while a failure is recorded
    /// AND something is serving (the F3 no-fallback case renders through
    /// modelStatusText instead).
    private var modelFailureText: String? {
        let provisioner = services.modelProvisioner
        guard let failure = provisioner.lastFailure,
              let serving = provisioner.servingModel else { return nil }
        return "\(failure.model.displayName) failed — reverted to \(serving.displayName): \(failure.message)"
    }
```

Update the ControlBar instantiation (~L92):

```swift
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError ?? modelFailureText,
                modelStatus: modelStatusText,
                canStartRecording: services.modelProvisioner.canStartRecording,
```

- [ ] **Step 3: startSession defensive guard**

At the top of `startSession` (~L497, before any state mutation):

```swift
        // UI gating makes this unreachable from the buttons; API starts and
        // races land here. Surfaced via the same error row the UI already has.
        guard services.modelProvisioner.canStartRecording else {
            transcriptionEngine?.lastError = "Transcription model not ready — check Settings ▸ Transcription"
            return
        }
```

- [ ] **Step 4: Build + commit**

Run: `cd /Users/nic/programming/tome/Tome && swift build && swift test`
Expected: SUCCESS / all PASS.

```bash
git add Tome/Sources/Tome/Views/ControlBar.swift Tome/Sources/Tome/Views/ContentView.swift
git commit -m "feat: gate recording on model readiness — DOWNLOADING MODEL status, disabled record buttons"
```

---

### Task 9: Settings ▸ Transcription model picker

**Files:**
- Modify: `Tome/Sources/Tome/Views/SettingsView.swift` (SettingsView signature L5-24, TranscriptionTab L143+)
- Modify: `Tome/Sources/Tome/App/TomeApp.swift` (Settings scene L118-120)
- Test: none automated (view layer; `retry()`/gating logic tested in Task 4; visual verification in Task 13).

**Interfaces:**
- Consumes: `ModelProvisioner` observables + `retry()` (Task 4); `TranscriberModel.displayName/pickerSubtitle/isInstalled/approxDownloadSize` (Tasks 1, 5); `AppServices.isRecording/isRecovering/postProcessingQueue.isAnyJobRunning` (Task 7).
- Produces: `SettingsView(settings:updater:services:)` — TomeApp updated to match.

- [ ] **Step 1: Thread services into SettingsView**

`SettingsView` gains `let services: AppServices` and passes it to the tab:

```swift
struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    let services: AppServices
    ...
            TranscriptionTab(settings: settings, services: services)
```

In `TomeApp.swift`:

```swift
        Settings {
            SettingsView(settings: settings, updater: updaterController.updater, services: services)
        }
```

- [ ] **Step 2: The Model section**

In `TranscriptionTab` (now `private struct TranscriptionTab: View { @Bindable var settings: AppSettings; let services: AppServices ... }`), add a `Section("Model")` **above** the existing `Section("Language")`:

```swift
            Section("Model") {
                Picker(selection: $settings.transcriberModel) {
                    ForEach(TranscriberModel.allCases, id: \.self) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(rowSubtitle(for: model))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .tag(model)
                    }
                } label: {
                    Text("Model").font(.system(size: 12, weight: .medium))
                }
                .pickerStyle(.radioGroup)
                .disabled(modelChangeLocked)

                if modelChangeLocked {
                    Text("Model changes are disabled while recording or processing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                modelStatusLine
            }
```

with the helpers on `TranscriptionTab`:

```swift
    /// Spec §4a: no swap may land mid-recording, mid-post-processing, or
    /// mid-recovery — a job re-transcribed by two models is a quality bug.
    private var modelChangeLocked: Bool {
        services.isRecording
            || services.postProcessingQueue.isAnyJobRunning
            || services.isRecovering
    }

    /// Per-row install state (spec §6): each row describes ITSELF; the
    /// status line below describes the selected model's provisioning.
    private func rowSubtitle(for model: TranscriberModel) -> String {
        let installState = model.isInstalled
            ? "Downloaded ✓"
            : "Not downloaded (\(model.approxDownloadSize))"
        return "\(model.pickerSubtitle) · \(installState)"
    }

    @ViewBuilder private var modelStatusLine: some View {
        let provisioner = services.modelProvisioner
        switch provisioner.activity {
        case .downloading(_, let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading model…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .none:
            if let failure = provisioner.lastFailure {
                HStack(spacing: 8) {
                    Text("\(failure.model.displayName): \(failure.message)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.recordRed)
                    Button("Retry") { provisioner.retry() }
                        .font(.system(size: 11))
                        .disabled(modelChangeLocked)
                }
            } else if provisioner.servingModel == settings.transcriberModel {
                Text("Active ✓")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading model…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 3: Build + commit**

Run: `cd /Users/nic/programming/tome/Tome && swift build && swift test`
Expected: SUCCESS / all PASS.

```bash
git add Tome/Sources/Tome/Views/SettingsView.swift Tome/Sources/Tome/App/TomeApp.swift
git commit -m "feat: Settings model picker with install state, provisioning status, and Retry"
```

---

### Task 10: API gating — both start endpoints + `/health`

**Files:**
- Modify: `Tome/Sources/Tome/API/APIServer.swift` (register L60-72, handleWhisperCalStart L343, handleStartSession L403, handleHealth L326-339, openAPISpec string ~L860+)
- Modify: `Tome/Sources/Tome/Views/ContentView.swift` (register call ~L180)
- Test: none automated (no APIServer test seam exists; verified with curl in Task 12).

**Interfaces:**
- Consumes: `ModelProvisioner.canStartRecording` (Task 4).
- Produces: `APIServer.register(transcriptStore:transcriptionEngine:sessionStore:canStartRecording:onStart:onStop:)`.

- [ ] **Step 1: Store the check**

Add near the other closures (~L31):

```swift
    /// Model readiness — sourced from ModelProvisioner via register().
    /// Replaces /health's assetStatus string-matching: semantics preserved
    /// ("a recording can start now"), response shape untouched (API freeze).
    private var canStartRecording: (() -> Bool)?
```

Extend `register` (insert the parameter before `onStart`) and assign it:

```swift
    func register(
        transcriptStore: TranscriptStore,
        transcriptionEngine: TranscriptionEngine,
        sessionStore: SessionStore,
        canStartRecording: @escaping () -> Bool,
        onStart: @escaping (SessionType, String, MeetingContext?, String?) -> Void,
        onStop: @escaping () -> Void
    ) {
```

- [ ] **Step 2: Gate both start handlers**

In `handleWhisperCalStart` AND `handleStartSession`, immediately after each one's existing already-recording guard (so "already recording" keeps winning as 409):

```swift
        guard canStartRecording?() ?? false else {
            return (503, #"{"error":"Transcription model not ready"}"#)
        }
```

- [ ] **Step 3: Re-source /health**

In `handleHealth`, replace the three-line string derivation with:

```swift
        let modelsReady = canStartRecording?() ?? false
```

(delete the `statusStr` local if now unused).

- [ ] **Step 4: Update ContentView's register call**

At ~L180 add the argument:

```swift
            canStartRecording: { services.modelProvisioner.canStartRecording },
```

- [ ] **Step 5: Document in the OpenAPI string**

In the `openAPISpec` literal, find the `/start` and `/sessions/start` path entries and add a 503 response line to each, matching the literal's existing formatting (e.g. `"503": {"description": "Transcription model not ready"}`). This is a hardcoded doc string — no behavior.

- [ ] **Step 6: Build + commit**

Run: `cd /Users/nic/programming/tome/Tome && swift build && swift test`
Expected: SUCCESS / all PASS.

```bash
git add Tome/Sources/Tome/API/APIServer.swift Tome/Sources/Tome/Views/ContentView.swift
git commit -m "feat: gate API start endpoints and /health modelsReady on model readiness"
```

---

### Task 11: `ASRBench` load-test CLI

**Files:**
- Create: `Tome/Sources/ASRBench/main.swift`
- Modify: `Tome/Package.swift` (add executable target)
- Test: none (diagnostic CLI, like VoiceprintAudit; its output IS the deliverable, produced in Task 12).

**Interfaces:**
- Consumes: FluidAudio (`AsrModels`, `AsrManager`, `TdtDecoderState`, and `VadManager.segmentSpeechAudio` — the same VAD the app uses, so chunking matches the live pipeline per spec §8) and WhisperKit directly. **Deliberate duplication:** SwiftPM forbids executable→executable dependencies, so ASRBench cannot import the app's backends (`TomeTests` gets away with it only because test targets may depend on executables). The variant/paths constants are copied with a pointer comment; VoiceprintAudit set this precedent.
- Produces: `swift run -c release ASRBench <wav/m4a files...> [--json out.json]` printing a comparison table.

- [ ] **Step 1: Package target**

In `Tome/Package.swift`, after the `VoiceprintAudit` target:

```swift
        // ASR load-test harness comparing Parakeet vs Whisper latency (see
        // docs/superpowers/specs/2026-07-08-*.md §8). Not part of the app;
        // never run in CI (downloads GBs of models, needs ANE).
        .executableTarget(
            name: "ASRBench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/ASRBench"
        ),
```

- [ ] **Step 2: Write the bench**

`Tome/Sources/ASRBench/main.swift` (top-level-code executable, VoiceprintAudit style). Swift 6 note: top-level *variables* are MainActor-isolated (SE-0343), so the bench functions take everything as parameters and never touch top-level state.

```swift
// ASRBench — compares Parakeet-TDT v3 (FluidAudio) and Whisper Large v3
// Turbo (WhisperKit) on identical audio, chunked the way the live pipeline
// chunks it (spec §8): VAD-bounded speech segments, split at the 480k-sample
// (~30s) flush ceiling, segments under ~0.5s dropped — the same caps
// StreamingTranscriber applies.
//
// Usage: swift run -c release ASRBench <wav/m4a...> [--json out.json]

import AVFoundation
import Foundation
import FluidAudio
import WhisperKit

// Mirrors WhisperBackend (Sources/Tome/Transcription/WhisperBackend.swift) —
// keep in sync; SwiftPM forbids importing the app executable from here.
let whisperFamily = "openai_whisper-large-v3-v20240930"
let whisperVariant = WhisperKit.recommendedModels().supported.contains(whisperFamily)
    ? whisperFamily : whisperFamily + "_626MB"
let whisperBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Tome/WhisperKit", isDirectory: true)

// Live-pipeline caps (see StreamingTranscriber.swift): flush at 480k samples,
// drop sub-8k segments ("Parakeet emits garbage below this").
let sampleRate = 16_000.0
let maxChunkSamples = 480_000
let minChunkSamples = 8_000

var argv = Array(CommandLine.arguments.dropFirst())
var jsonOut: String?
if let i = argv.firstIndex(of: "--json"), i + 1 < argv.count {
    jsonOut = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
}
let files = argv
guard !files.isEmpty else {
    print("usage: ASRBench <wav/m4a files...> [--json out.json]")
    exit(1)
}

struct ChunkTiming: Codable {
    let seconds: Double
    let latency: Double
    var rtf: Double { latency / seconds }
}

struct BackendReport: Codable {
    let name: String
    let variant: String
    let downloadSeconds: Double?     // nil when already cached
    let diskSizeMB: Double
    let loadSecondsCold: Double
    let loadSecondsWarm: Double
    let firstTranscribeSeconds: Double   // ANE warm-up shows up here
    let timings: [ChunkTiming]
    let peakRSSMB: Double
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

func directorySizeMB(_ url: URL) -> Double {
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total = 0
    for case let file as URL in enumerator {
        total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
    }
    return Double(total) / 1_048_576
}

func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576.0   // ru_maxrss is bytes on macOS
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }

// --- Parakeet ---
func benchParakeet(chunks: [[Float]]) async throws -> BackendReport {
    let cached = AsrModels.modelsExist(
        at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    let tDownload = now()
    let dir = try await AsrModels.download(version: .v3)
    let downloadSeconds: Double? = cached ? nil : now() - tDownload

    let tCold = now()
    let coldModels = try await AsrModels.load(from: dir, version: .v3)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(coldModels)
    let loadCold = now() - tCold

    await asr.cleanup()
    let tWarm = now()
    let warmModels = try await AsrModels.load(from: dir, version: .v3)
    try await asr.loadModels(warmModels)
    let loadWarm = now() - tWarm

    func transcribe(_ samples: [Float]) async throws -> Double {
        var state = TdtDecoderState.make()
        let t = now()
        _ = try await asr.transcribe(samples, decoderState: &state, language: .english)
        return now() - t
    }

    let tFirst = try await transcribe(chunks[0])
    var timings: [ChunkTiming] = []
    for chunk in chunks {
        timings.append(ChunkTiming(
            seconds: Double(chunk.count) / sampleRate,
            latency: try await transcribe(chunk)))
    }
    return BackendReport(
        name: "Parakeet-TDT v3", variant: "parakeet-tdt-0.6b-v3 int8",
        downloadSeconds: downloadSeconds, diskSizeMB: directorySizeMB(dir),
        loadSecondsCold: loadCold, loadSecondsWarm: loadWarm,
        firstTranscribeSeconds: tFirst, timings: timings, peakRSSMB: peakRSSMB())
}

// --- Whisper ---
func benchWhisper(chunks: [[Float]], variant: String, base: URL) async throws -> BackendReport {
    let expectedFolder = base.appendingPathComponent(
        "models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    let cached = FileManager.default.fileExists(
        atPath: expectedFolder.appendingPathComponent("TextDecoder.mlmodelc").path)
    let tDownload = now()
    let folder = try await WhisperKit.download(
        variant: variant, downloadBase: base,
        progressCallback: { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 10 == 0 { print("whisper download: \(pct)%") }
        })
    let downloadSeconds: Double? = cached ? nil : now() - tDownload

    let config = WhisperKitConfig(
        model: variant, downloadBase: base,
        modelFolder: folder.path, load: true, download: false)
    let tCold = now()
    do { _ = try await WhisperKit(config) }   // cold load; instance released at scope end
    let loadCold = now() - tCold
    let tWarm = now()
    let kit = try await WhisperKit(config)
    let loadWarm = now() - tWarm

    func transcribe(_ samples: [Float]) async throws -> Double {
        let t = now()
        _ = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(task: .transcribe, language: "en"))
        return now() - t
    }

    let tFirst = try await transcribe(chunks[0])
    var timings: [ChunkTiming] = []
    for chunk in chunks {
        timings.append(ChunkTiming(
            seconds: Double(chunk.count) / sampleRate,
            latency: try await transcribe(chunk)))
    }
    return BackendReport(
        name: "Whisper Large v3 Turbo", variant: variant,
        downloadSeconds: downloadSeconds, diskSizeMB: directorySizeMB(folder),
        loadSecondsCold: loadCold, loadSecondsWarm: loadWarm,
        firstTranscribeSeconds: tFirst, timings: timings, peakRSSMB: peakRSSMB())
}

func printReport(_ r: BackendReport) {
    let latencies = r.timings.map(\.latency)
    let rtfs = r.timings.map(\.rtf)
    print("""

    == \(r.name) (\(r.variant)) ==
    download:        \(r.downloadSeconds.map { String(format: "%.0f", $0) + "s" } ?? "cached")
    on disk:         \(String(format: "%.0f", r.diskSizeMB)) MB
    load cold/warm:  \(String(format: "%.1f", r.loadSecondsCold))s / \(String(format: "%.1f", r.loadSecondsWarm))s
    first transcribe (warm-up): \(String(format: "%.2f", r.firstTranscribeSeconds))s
    chunk latency:   p50 \(String(format: "%.2f", percentile(latencies, 0.5)))s  p95 \(String(format: "%.2f", percentile(latencies, 0.95)))s
    RTF:             p50 \(String(format: "%.3f", percentile(rtfs, 0.5)))  p95 \(String(format: "%.3f", percentile(rtfs, 0.95)))
    peak RSS:        \(String(format: "%.0f", r.peakRSSMB)) MB
    chunks:          \(r.timings.count) totaling \(String(format: "%.0f", r.timings.map(\.seconds).reduce(0, +)))s
    """)
}

// --- Top-level: load audio, VAD-segment it, run both benches ---
var allSamples: [Float] = []
for file in files {
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: file)
    allSamples.append(contentsOf: samples)
    print("loaded \(file): \(String(format: "%.0f", Double(samples.count) / sampleRate))s")
}

// Same VAD the app uses, same caps as StreamingTranscriber: speech segments,
// split at the ~30s flush ceiling, sub-0.5s dropped.
let vad = try await VadManager()
var chunks: [[Float]] = []
for segment in try await vad.segmentSpeechAudio(allSamples) {
    var offset = 0
    while offset < segment.count {
        let end = min(offset + maxChunkSamples, segment.count)
        if end - offset >= minChunkSamples {
            chunks.append(Array(segment[offset..<end]))
        }
        offset = end
    }
}
guard !chunks.isEmpty else {
    print("error: VAD found no speech ≥0.5s in the input — use a fixture with real speech")
    exit(1)
}
let chunkSummary = chunks.map { Double($0.count) / sampleRate }
print("VAD chunks: \(chunks.count) (\(String(format: "%.1f", chunkSummary.min()!))s–\(String(format: "%.1f", chunkSummary.max()!))s)")

// Parakeet first (already cached on any machine that has run Tome), then Whisper.
let parakeet = try await benchParakeet(chunks: chunks)
printReport(parakeet)
let whisper = try await benchWhisper(chunks: chunks, variant: whisperVariant, base: whisperBase)
printReport(whisper)

let whisperP95 = percentile(whisper.timings.map(\.rtf), 0.95)
print("\nAcceptance bar (spec §8): live use wants p95 RTF < 0.5.")
print("Whisper p95 RTF = \(String(format: "%.3f", whisperP95)) → \(whisperP95 < 0.5 ? "PASS" : "MISS — ship with 'may lag during live transcription' copy")")

if let jsonOut {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode([parakeet, whisper]).write(to: URL(fileURLWithPath: jsonOut))
    print("wrote \(jsonOut)")
}
```

Notes:
- Peak RSS is process-wide, so Whisper's figure (measured second) includes Parakeet residue — treat it as an upper bound, or run each backend in its own invocation for clean numbers.
- `.mlmodelc` vs `.mlpackage` in the `cached` check: if the downloaded variant folder uses `.mlpackage`, mirror what `WhisperBackend.isInstalled()` checks.
- The nested `transcribe` helpers close over actor/class references only (no top-level state), so top-level isolation is not an issue; if the compiler still complains about an SDK signature, the checkout under `Tome/.build/checkouts/` is the authority.


- [ ] **Step 3: Build only**

Run: `cd /Users/nic/programming/tome/Tome && swift build --target ASRBench`
Expected: SUCCESS. Do NOT run it yet (Task 12 does, with a fixture).

- [ ] **Step 4: Commit**

```bash
git add Tome/Package.swift Tome/Sources/ASRBench/main.swift
git commit -m "feat: ASRBench CLI — Parakeet vs Whisper latency/RTF comparison"
```

---

### Task 12: Full verification + benchmark run

**Files:** none created (evidence-gathering task). Benchmark numbers land in `docs/superpowers/plans/2026-07-08-benchmark-results.md`.

- [ ] **Step 1: Full build + suite + selfcheck (CI parity)**

```bash
cd /Users/nic/programming/tome/Tome
swift build && swift test && swift run Tome --selfcheck
```
Expected: build SUCCESS, all tests PASS, selfcheck exits 0.

- [ ] **Step 2: Synthesize a speech fixture**

Real speech matters: Whisper is autoregressive — silence decodes unrealistically fast, inflating its numbers. The `[[slnc 1200]]` pauses make the VAD produce realistic utterance-sized chunks instead of one continuous block:

```bash
mkdir -p /tmp/asrbench
say -o /tmp/asrbench/fixture.aiff "$(python3 -c "print(('The quarterly infrastructure review covered database migration timelines, service level objectives, and the incident retrospective from last Tuesday. [[slnc 1200]] ' * 30))")"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/asrbench/fixture.aiff /tmp/asrbench/fixture.wav
afinfo /tmp/asrbench/fixture.wav | head -5
```
Expected: a WAV of ≥ 120 seconds (each sentence ≈ 9s spoken + 1.2s pause, × 30). If shorter than 30s, increase the multiplier. ASRBench prints its VAD chunk count/range — expect roughly 30 chunks of ~8–10s each.

- [ ] **Step 3: Run the bench** (downloads ~600 MB Parakeet if not cached + 0.6–1.5 GB Whisper on first run; needs network)

```bash
cd /Users/nic/programming/tome/Tome
swift run -c release ASRBench /tmp/asrbench/fixture.wav --json /tmp/asrbench/results.json
```
Expected: two report blocks + the acceptance-bar line. Save the console output.

- [ ] **Step 4: Record results**

Write `docs/superpowers/plans/2026-07-08-benchmark-results.md` containing: the machine (chip, RAM, macOS), the resolved Whisper variant, both report blocks verbatim, the PASS/MISS verdict, and the decision it implies (plain drop-down copy vs adding "may lag during live transcription" to `TranscriberModel.pickerSubtitle` for `.whisperLargeV3Turbo`). **If MISS:** apply the copy change to `pickerSubtitle` now (one-line edit + updated TranscriberModelTests expectation if the subtitle is asserted).

- [ ] **Step 5: Commit**

```bash
cd /Users/nic/programming/tome
git add docs/superpowers/plans/2026-07-08-benchmark-results.md
# If Step 4's MISS branch changed the picker copy, stage that too:
# git add Tome/Sources/Tome/Transcription/TranscriberModel.swift Tome/Tests/TomeTests/TranscriberModelTests.swift
git commit -m "docs: ASRBench results — Parakeet vs Whisper Large v3 Turbo on this machine"
```

---

### Task 13: Smoke tests + state-audit agent pass (final gate)

**Files:** none (verification + any fixes it forces).

- [ ] **Step 1: API-driven smoke, Parakeet** (app runs headed; needs mic permission already granted)

The server binds a dynamic port on 127.0.0.1 and writes it to
`~/Library/Application Support/Tome/api-port`:

```bash
cd /Users/nic/programming/tome/Tome && swift run Tome &
sleep 8
PORT=$(cat ~/Library/Application\ Support/Tome/api-port)
curl -s "http://127.0.0.1:$PORT/health"
```
Expected: `"modelsReady":true` once Parakeet is provisioned (first ever run: watch the app's DOWNLOADING MODEL state clear first).
Start a voice memo, generate real speech at the mic, stop, and verify:

```bash
curl -s -X POST "http://127.0.0.1:$PORT/sessions/start" -d '{"type":"voiceMemo"}'
say "The quick brown fox jumps over the lazy dog. Testing Tome smoke pass."
sleep 15
curl -s -X POST "http://127.0.0.1:$PORT/sessions/stop"
sleep 20
ls -t ~/Documents/Tome/Voice | head -2   # transcript written
```

Then the call-capture path (spec §9 requires both session types per model — call capture exercises system-audio capture and the `POST /start` handler, a different route than `/sessions/start`). Play any audio (e.g. a YouTube video) so the system leg has signal:

```bash
curl -s -X POST "http://127.0.0.1:$PORT/start"
say "Call capture smoke pass, speaking on the mic side."
sleep 15
curl -s -X POST "http://127.0.0.1:$PORT/stop"
sleep 20
ls -t ~/Documents/Tome/Meetings | head -2   # transcript written
```

- [ ] **Step 2: Switch to Whisper in Settings** (manual, app still running)

Settings ▸ Transcription → select Whisper Large v3 Turbo. Verify in order: status line shows Downloading with %, ControlBar shows DOWNLOADING MODEL… with buttons disabled, `curl -s "http://127.0.0.1:$PORT/health"` says `"modelsReady":false`, then everything flips ready when the download completes. Repeat BOTH Step 1 smokes (voice memo AND call capture) on Whisper; verify live transcript appears and the final transcript is written after stop.

- [ ] **Step 3: Failure + revert smoke** (manual)

1. Delete the Whisper cache: `rm -rf ~/Library/Application\ Support/Tome/WhisperKit`
2. Turn Wi-Fi off. Relaunch the app with Whisper selected.
3. Expected: DOWNLOAD fails → selection reverts to Parakeet (Settings shows the Whisper failure + Retry), recording is ENABLED (Parakeet cached), main screen shows the reverted-failure line.
4. Turn Wi-Fi on → Retry → expect download to proceed and Whisper to activate.
5. While a post-processing job runs (record + stop a memo, immediately open Settings): picker is disabled with the caption.

- [ ] **Step 3b: Cache-deletion re-download smoke, Parakeet side** (spec §9)

Quit the app, then:

```bash
rm -rf ~/Library/Application\ Support/FluidAudio/Models
```

Relaunch with Parakeet selected (network on). Expected: DOWNLOADING MODEL… appears (recording gated), Parakeet re-downloads and activates, recording re-enables — the deleted cache is rediscovered at provision time, not crashed on.

- [ ] **Step 4: Existing-suite + CI parity re-run**

```bash
cd /Users/nic/programming/tome/Tome && swift test && swift run Tome --selfcheck
```
Expected: all PASS.

- [ ] **Step 5: State-audit agent pass**

Dispatch a fresh agent (orchestrator does this; not a code step) with this charter:

> Read spec §4/§4a/§9 (docs/superpowers/specs/2026-07-08-whisper-v3-turbo-model-option-design.md) and the implementation (ModelProvisioner.swift, ASRCoordinator.swift, ParakeetBackend.swift, WhisperBackend.swift, and the wiring in ContentView/TomeApp/AppServices/SettingsView/ControlBar/APIServer/Recovery). Enumerate the full matrix: {selected model} × {installed / not installed} × {network up / down} × {recording active / post-processing or recovery in flight / idle} × {app relaunched mid-download} × {cache deleted between launches} × {first run / has last-good / last-good itself fails}. Trace each cell through the code. Hunt specifically for: recording disabled with no recovery path; failures with no Retry affordance; revert recursion; selection/serving/last-good desync; stale-generation outcomes mutating state; unload-under-use; stale UI (says downloading, nothing in flight). Report each finding with the cell, the code path, and the failure. Findings must be fixed (with a test where the state machine is at fault) before the branch is done.

- [ ] **Step 6: Fix confirmed findings, re-run the full suite, commit**

```bash
cd /Users/nic/programming/tome/Tome && swift test
git add -A && git commit -m "fix: state-audit findings"   # only if there were findings
```

---

## Execution notes

- Tasks 1→5 are strictly ordered (each consumes the previous task's types). Tasks 6+7 form one commit. Tasks 8, 9, 10 are independent of each other (all depend on 7). Task 11 is independent of 6–10. Tasks 12–13 come last.
- If any pinned-SDK signature disagrees with this plan, the checkout under `Tome/.build/checkouts/` is the authority — fix the call site, note it in the commit message, and keep the spec's behavior.
- The spec (docs/superpowers/specs/2026-07-08-whisper-v3-turbo-model-option-design.md) governs behavior questions this plan doesn't answer. If plan and spec conflict, the spec wins; flag the conflict rather than improvising.



