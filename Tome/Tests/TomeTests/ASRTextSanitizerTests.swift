import Testing
@testable import Tome

/// Parakeet v3's vocab lacks several printable characters (& @ # + …); the
/// decoder emits a literal `<unk>` token in their place. The sanitizer maps
/// the tight-acronym case to "&" and drops the rest cleanly.
@Suite struct ASRTextSanitizerTests {

    @Test func ampersandBetweenAlphanumerics() {
        #expect(ASRTextSanitizer.sanitize("the P<unk>L review") == "the P&L review")
        #expect(ASRTextSanitizer.sanitize("our R<unk>D budget") == "our R&D budget")
        #expect(ASRTextSanitizer.sanitize("AT<unk>T called") == "AT&T called")
        #expect(ASRTextSanitizer.sanitize("the S<unk>P 500") == "the S&P 500")
    }

    @Test func standaloneUnkIsDroppedWithCleanSpacing() {
        #expect(ASRTextSanitizer.sanitize("profit <unk> loss") == "profit loss")
        #expect(ASRTextSanitizer.sanitize("<unk> leading") == "leading")
        #expect(ASRTextSanitizer.sanitize("trailing <unk>") == "trailing")
        #expect(ASRTextSanitizer.sanitize("<unk>") == "")
        #expect(ASRTextSanitizer.sanitize("glued<unk>, punctuation") == "glued, punctuation")
    }

    @Test func multipleUnksInOneUtterance() {
        #expect(ASRTextSanitizer.sanitize("M<unk>A and <unk> the R<unk>D team") == "M&A and the R&D team")
    }

    @Test func cleanTextPassesThroughUntouched() {
        let clean = "no artifacts here, P&L already fine"
        #expect(ASRTextSanitizer.sanitize(clean) == clean)
        // Multi-space runs in clean text are none of the sanitizer's business.
        let spaced = "already  double  spaced"
        #expect(ASRTextSanitizer.sanitize(spaced) == spaced)
    }
}
