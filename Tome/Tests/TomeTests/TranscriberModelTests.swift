import Foundation
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
