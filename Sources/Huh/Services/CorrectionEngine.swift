import Foundation

/// Applies dictionary corrections to a completed transcript.
///
/// Four properties, each with a specific failure it prevents:
///
///  * **Whole-word matching.** A multi-word trigger must never match inside a
///    longer word. Patterns are fenced with lookarounds rejecting an adjacent
///    letter, digit, hyphen or apostrophe. `\b` is insufficient because it
///    treats a hyphen as a boundary, which would allow a match inside a
///    hyphenated compound.
///
///  * **Separator tolerance.** Recognisers emit the same utterance with and
///    without separators. Any run of whitespace, hyphens or underscores —
///    including none — is accepted between the words of a trigger.
///
///  * **Longest trigger wins.** A more specific trigger takes precedence over a
///    prefix of itself.
///
///  * **Single non-overlapping pass.** Matches are collected against the
///    original text and applied in reverse order. Applying rules sequentially
///    would allow one rule's output to be consumed by another.
enum CorrectionEngine {

    struct Result {
        var text: String
        var applied: [AppliedCorrection]
    }

    /// Builds the pattern for a trigger phrase. Returns nil if unusable.
    static func pattern(for hear: String) -> String? {
        let words = hear
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }

        let core = words.joined(separator: "[\\s\\-_]*")
        // Reject an adjacent letter, digit, hyphen or apostrophe. Hyphens
        // matter in both directions: a hyphen *within* the trigger is accepted
        // as a separator, while a hyphen immediately before or after the match
        // indicates a different compound word.
        return "(?<![\\p{L}\\p{N}'\\-])" + core + "(?![\\p{L}\\p{N}'\\-])"
    }

    static func regex(for hear: String) -> NSRegularExpression? {
        guard let pattern = pattern(for: hear) else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func apply(_ text: String, corrections: [CorrectionPair]) -> Result {
        guard !text.isEmpty else { return Result(text: text, applied: []) }

        let active = corrections
            .filter { $0.enabled && !$0.hear.trimmed.isEmpty && !$0.write.isEmpty }
            .sorted { $0.hear.count > $1.hear.count }   // longest trigger wins

        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        struct Hit {
            let range: NSRange
            let pair: CorrectionPair
            let matched: String
        }

        var hits: [Hit] = []
        var claimed: [NSRange] = []

        for pair in active {
            guard let regex = regex(for: pair.hear) else { continue }
            for match in regex.matches(in: text, options: [], range: whole) {
                let range = match.range
                // Skip ranges already claimed by a longer trigger.
                let overlaps = claimed.contains { NSIntersectionRange($0, range).length > 0 }
                if overlaps { continue }
                claimed.append(range)
                hits.append(Hit(range: range, pair: pair, matched: ns.substring(with: range)))
            }
        }

        guard !hits.isEmpty else { return Result(text: text, applied: []) }

        // Apply in reverse so earlier ranges remain valid.
        let mutable = NSMutableString(string: text)
        for hit in hits.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: hit.range, with: hit.pair.write)
        }

        let applied = hits
            .sorted { $0.range.location < $1.range.location }
            .map { AppliedCorrection(hear: $0.pair.hear, write: $0.pair.write, matched: $0.matched) }

        return Result(text: mutable as String, applied: applied)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
