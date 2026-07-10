import Foundation
import FluidAudio

/// Cleans decoder artifacts out of ASR text before it reaches the transcript
/// store or any file. Parakeet v3's 8k SentencePiece vocab has no tokens for a
/// number of printable characters (& @ # ( ) + ; = [ ] { } ^ ~ …), so the
/// decoder emits the literal `<unk>` token where the model "hears" one —
/// field-observed as "P<unk>L" for "P&L" in the live transcript window.
///
/// The original character is unrecoverable from the token stream, so two rules
/// approximate intent:
///  • `<unk>` packed tightly between letters/digits renders as "&" — the
///    dominant spoken pattern that lands there (P&L, R&D, M&A, AT&T, S&P).
///  • Every other `<unk>` is dropped, with whitespace re-collapsed, so an
///    unrecoverable symbol degrades to a clean omission instead of markup.
///
/// Applied centrally in `ASRCoordinator.transcribe` so live streaming and
/// batch re-transcription both pass through it.
enum ASRTextSanitizer {

    private static let unkToken = "<unk>"

    private static let ampersandContext = try? NSRegularExpression(
        pattern: #"(?<=[\p{L}\p{N}])<unk>(?=[\p{L}\p{N}])"#
    )
    private static let doubleSpaces = try? NSRegularExpression(pattern: #" {2,}"#)

    static func sanitize(_ text: String) -> String {
        guard text.contains(unkToken) else { return text }
        var s = text
        if let ampersandContext {
            s = ampersandContext.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "&"
            )
        }
        s = s.replacingOccurrences(of: unkToken, with: "")
        if let doubleSpaces {
            s = doubleSpaces.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " "
            )
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Copy of `result` with sanitized text; returns the original instance
    /// untouched when there's nothing to clean (the common case).
    static func sanitized(_ result: ASRResult) -> ASRResult {
        let clean = sanitize(result.text)
        guard clean != result.text else { return result }
        // tokenTimings are left as-is: they carry their own per-token text and
        // Tome never renders them, so realigning them isn't worth the code.
        return ASRResult(
            text: clean,
            confidence: result.confidence,
            duration: result.duration,
            processingTime: result.processingTime,
            tokenTimings: result.tokenTimings,
            performanceMetrics: result.performanceMetrics,
            ctcDetectedTerms: result.ctcDetectedTerms,
            ctcAppliedTerms: result.ctcAppliedTerms
        )
    }
}
