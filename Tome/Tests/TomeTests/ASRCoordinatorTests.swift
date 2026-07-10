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
        await coordinator.install(backend: backend, token: 1)
        #expect(await coordinator.isReady)
        #expect(await coordinator.activeModel == .parakeetTDTv3)
        let result = try await coordinator.transcribe(samples: [0.0], source: .microphone)
        #expect(result.text == "fake:parakeet-tdt-v3")
    }

    @Test func swapWithNoInFlightCallsUnloadsOldImmediately() async throws {
        let coordinator = ASRCoordinator()
        let old = FakeBackend(model: .parakeetTDTv3)
        let new = FakeBackend(model: .whisperLargeV3Turbo)
        await coordinator.install(backend: old, token: 1)
        await coordinator.install(backend: new, token: 2)
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
        await coordinator.install(backend: old, token: 1)
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

        await coordinator.install(backend: new, token: 2)
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

    /// Token-ordered installs (audit F-1): a lower-token install arriving AFTER
    /// a higher one is stale. It must not swap in its backend; the stale backend
    /// is unloaded exactly once, and the winner is left serving with no unload.
    @Test func lowerTokenInstallArrivingLateIsRefusedAndUnloaded() async throws {
        let coordinator = ASRCoordinator()
        let p = FakeBackend(model: .parakeetTDTv3)
        let w = FakeBackend(model: .whisperLargeV3Turbo)
        let x = FakeBackend(model: .parakeetTDTv3)

        await coordinator.install(backend: p, token: 1)
        await coordinator.install(backend: w, token: 3)
        await coordinator.install(backend: x, token: 2)   // stale: 2 <= 3

        #expect(await coordinator.activeModel == .whisperLargeV3Turbo)
        #expect(await x.unloadCalls == 1)   // stale incoming backend released
        #expect(await w.unloadCalls == 0)   // winner untouched
    }

    /// Re-asserting the ALREADY-ACTIVE backend under a higher token (the
    /// flip-back re-assert path) is a no-op swap: it records the token to
    /// outrank any in-flight stale install but never unloads the live backend.
    @Test func reassertingActiveBackendWithHigherTokenDoesNotUnloadIt() async throws {
        let coordinator = ASRCoordinator()
        let p = FakeBackend(model: .parakeetTDTv3)

        await coordinator.install(backend: p, token: 1)
        await coordinator.install(backend: p, token: 5)   // re-assert, higher token

        #expect(await coordinator.activeModel == .parakeetTDTv3)
        #expect(await p.unloadCalls == 0)   // active backend never unloaded
    }

    /// I-1 Trace A, deterministic: `install` suspends inside the old backend's
    /// `unload()`, and a reentrant higher-token re-assert of the OLD backend
    /// interleaves at that suspension point. The suspended install must
    /// re-validate its token after the suspension and, finding it outranked,
    /// abandon its swap (unloading its own incoming backend) rather than
    /// clobbering the re-asserted winner.
    @Test func installRevalidatesTokenAcrossUnloadSuspension() async throws {
        let coordinator = ASRCoordinator()
        let p = FakeBackend(model: .parakeetTDTv3)
        let w = FakeBackend(model: .whisperLargeV3Turbo)

        await coordinator.install(backend: p, token: 1)
        await p.setHangUnload(true)

        // W-install (token 2) will retire P and suspend inside P.unload().
        let wInstall = Task { await coordinator.install(backend: w, token: 2) }
        // Wait until that install is actually parked in P's unload.
        for _ in 0..<100 {
            if await p.unloadStarted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await p.unloadStarted == 1)

        // Reentrant re-assert of P under a higher token. old === backend, so
        // the retire is skipped and this completes without suspending on P's
        // (hung) unload; it records token 3, outranking the parked W-install.
        await coordinator.install(backend: p, token: 3)
        #expect(await coordinator.activeModel == .parakeetTDTv3)

        // Release P's unload so the W-install resumes past its suspension and
        // hits the re-validation guard.
        await p.releaseUnload()
        await wInstall.value

        // W lost the race: it was never installed, and it unloaded its own
        // orphaned incoming backend exactly once.
        #expect(await coordinator.activeModel == .parakeetTDTv3)
        #expect(await w.unloadCalls == 1)
        #expect(await w.transcribesStarted == 0)

        // And transcribes still route to P, never to W.
        let routed = try await coordinator.transcribe(samples: [0.0], source: .microphone)
        #expect(routed.text == "fake:parakeet-tdt-v3")
        #expect(await w.transcribesStarted == 0)
    }
}
