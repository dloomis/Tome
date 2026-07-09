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
    /// The backend instance behind `servingModel`. Held so a flip-back can
    /// re-assert it into the coordinator under a fresh token, outranking any
    /// in-flight stale install from the cancelled swap cycle (audit F-1).
    private var servingBackend: (any ASRBackend)?
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
    /// The fire-and-forget re-assert kicked off by a flip-back (below). Tracked
    /// so a rapid second flip-back cancels the prior re-assert before starting
    /// a new one, rather than leaking overlapping untracked tasks.
    private var reassertTask: Task<Void, Never>?

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
                // The cancelled swap may have an install already in flight
                // (coordinator.install suspends at old.unload()). Re-assert the
                // serving backend under the fresh token so that stale install is
                // outranked and refused. Token ordering makes the ordering race
                // harmless, and re-installing the already-active backend is a
                // no-op swap in the coordinator.
                if let sb = servingBackend {
                    let t = generation
                    reassertTask?.cancel()
                    reassertTask = Task {
                        // The serving backend's manager may have been unloaded
                        // out from under us: if the superseded cycle's install
                        // completed and then drained before this re-assert ran,
                        // the coordinator already unloaded it. prepare() is an
                        // idempotent guard-on-nil, so this reloads from local
                        // disk with no download; if it throws (e.g. cache
                        // deleted) install anyway — a not-ready backend surfaces
                        // as .notInitialized and the next provision fixes it.
                        try? await sb.prepare { _ in }
                        await coordinator.install(backend: sb, token: t)
                    }
                }
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
            await coordinator.install(backend: backend, token: gen)
            guard generation == gen else {
                // Superseded during install: the newer cycle's install (or a
                // flip-back's token-ordered re-assert) outranks this one and
                // retires this backend; its state writes own the machine now.
                return
            }
            servingModel = model
            servingBackend = backend
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
