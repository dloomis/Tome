import Foundation

/// Sanitize user-configurable filename pieces (date-format output, type labels,
/// context strings) so they're safe on APFS, network shares, and cross-platform
/// sync targets. Replaces filesystem-hostile chars with `-`, drops control
/// characters, strips leading dots, trims whitespace, collapses repeated dashes,
/// and caps length. Returns `nil` if the result is empty after cleaning.
enum FilenameSanitizer {
    /// Chars that are either forbidden (`/`, NUL) or cause problems on common
    /// destinations (Windows reserved set, colon for legacy HFS path semantics).
    private static let forbidden: Set<Character> = [
        "/", "\\", ":", "?", "*", "<", ">", "|", "\"", "\0"
    ]

    static func sanitize(_ raw: String, maxLength: Int = 200) -> String? {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if forbidden.contains(ch) {
                out.append("-")
            } else if let scalar = ch.unicodeScalars.first,
                      scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            } else {
                out.append(ch)
            }
        }

        while out.first == "." { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)

        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }

        if out.count > maxLength {
            out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }

        return out.isEmpty ? nil : out
    }

    /// Format `date` with `format`, then sanitize. Falls back to ISO-style if
    /// the format produces something invalid or empty.
    static func formattedDate(_ date: Date, format: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = format
        let raw = fmt.string(from: date)
        if let cleaned = sanitize(raw), !cleaned.isEmpty {
            return cleaned
        }
        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return fallback.string(from: date)
    }

    /// Tome's default note stem when no suggested filename applies:
    /// `"<date> <label>"`. `typeLabel == nil` means "no user override" and uses
    /// `fallbackLabel`; an empty label is a valid override meaning a date-only
    /// stem; a non-empty label is sanitized, falling back to `fallbackLabel` if
    /// sanitizing wipes it out (e.g. the user typed only forbidden chars).
    ///
    /// The single source of truth for this derivation: `TranscriptLogger.startSession`
    /// names new notes with it, and `TranscriptFinalizer.retypeAsVoiceMemo` uses it
    /// both to recognize Tome's own default call name and to produce the voice
    /// default — so the two can never drift apart.
    static func defaultTranscriptStem(
        start: Date,
        dateFormat: String,
        typeLabel: String?,
        fallbackLabel: String
    ) -> String {
        let datePrefix = formattedDate(start, format: dateFormat)
        let chosen = typeLabel ?? fallbackLabel
        let label = chosen.isEmpty ? "" : (sanitize(chosen) ?? fallbackLabel)
        return label.isEmpty ? datePrefix : "\(datePrefix) \(label)"
    }
}
