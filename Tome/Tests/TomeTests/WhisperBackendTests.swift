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
