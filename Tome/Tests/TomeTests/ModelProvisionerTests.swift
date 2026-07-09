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
