import Foundation

enum CleanupLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case standard
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "Off"
        case .standard:   return "Fillers & stutters"
        case .aggressive: return "Also hedges"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Keep the transcript exactly as spoken."
        case .standard:
            return "Drops “uh”, “um”, “erm” and collapses “yeah, yeah, yeah” into one. Conservative — it only removes words that carry no meaning."
        case .aggressive:
            return "Also drops hedges: “you know”, “I mean”, “sort of”, “basically”, “actually”. Reads tighter, but it is editing you, not just cleaning you up."
        }
    }
}

/// Removes disfluency from transcribed speech.
///
/// The criterion for removing a token is that its absence cannot change meaning.
/// Interjections such as "uh" satisfy this; "like" does not, since it is both a
/// filler and a content word, and the two cannot be distinguished reliably by
/// pattern matching.
///
/// Implemented entirely with regular expressions: no model, no network, and no
/// measurable cost.
enum TextCleanup {

    struct Result {
        var text: String
        var removed: Int
        /// Human-readable summary for the transcript audit trail.
        var summary: String {
            removed == 0 ? "nothing removed" : "\(removed) filler\(removed == 1 ? "" : "s") removed"
        }
    }

    /// Interjections that never carry meaning as standalone words.
    private static let fillers = ["uh", "uhh", "uhm", "um", "umm", "erm", "er", "ah", "hmm", "mmm", "mhm"]

    /// Discourse markers that are commonly repeated. A doubled discourse marker
    /// is a verbal tic, whereas a doubled content word may be grammatical
    /// ("that had had errors"), which is why this is an explicit list rather
    /// than a general rule.
    private static let stutterProne = ["yeah", "yes", "no", "okay", "ok", "right", "so", "well",
                                       "sure", "exactly", "true", "nope", "hey", "wait"]

    /// Hedges. Removing these edits meaning slightly, so it is opt-in.
    private static let hedges = ["you know", "i mean", "sort of", "kind of", "kinda", "sorta",
                                 "basically", "actually", "literally", "obviously", "essentially"]

    static func apply(_ text: String, level: CleanupLevel) -> Result {
        guard level != .off, !text.isEmpty else { return Result(text: text, removed: 0) }

        var working = text
        var removed = 0

        // 1. Standalone fillers, with any punctuation clinging to them.
        let fillerPattern = "(?i)(?<![\\p{L}\\p{N}'\\-])(?:\(fillers.joined(separator: "|")))(?![\\p{L}\\p{N}'\\-])[\\s,]*"
        removed += replace(&working, pattern: fillerPattern, with: "")

        if level == .aggressive {
            let hedgePattern = "(?i)(?<![\\p{L}\\p{N}'\\-])(?:\(hedges.map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")))(?![\\p{L}\\p{N}'\\-])[\\s,]*"
            removed += replace(&working, pattern: hedgePattern, with: "")
        }

        // 2. Doubled discourse words: "yeah, yeah, yeah" -> "yeah".
        let stutterPattern = "(?i)(?<![\\p{L}\\p{N}'\\-])(\(stutterProne.joined(separator: "|")))((?:[,\\s]+\\1)+)(?![\\p{L}\\p{N}'\\-])"
        removed += replace(&working, pattern: stutterPattern, with: "$1")

        // 3. Any word repeated three or more times — a stumble in any vocabulary.
        removed += replace(&working, pattern: "(?i)(?<![\\p{L}\\p{N}'\\-])(\\p{L}+)((?:[,\\s]+\\1){2,})(?![\\p{L}\\p{N}'\\-])", with: "$1")

        // 4. Normalise punctuation and whitespace left behind by removals.
        _ = replace(&working, pattern: "\\s+([,.!?;:])", with: "$1")
        _ = replace(&working, pattern: "([,;:])\\s*([,.!?;:])", with: "$2")
        _ = replace(&working, pattern: "([.!?])\\s*,", with: "$1")
        _ = replace(&working, pattern: "[ \\t]{2,}", with: " ")
        _ = replace(&working, pattern: "(?m)^[\\s,]+", with: "")

        // 5. Restore sentence capitalisation where a removal exposed a new
        //    sentence start.
        working = capitaliseSentences(working)

        return Result(text: working.trimmingCharacters(in: .whitespacesAndNewlines), removed: removed)
    }

    @discardableResult
    private static func replace(_ text: inout String, pattern: String, with template: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return 0 }
        text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        return count
    }

    private static func capitaliseSentences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(^|[.!?]\\s+)(\\p{Ll})") else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches where match.numberOfRanges == 3 {
            let letterRange = match.range(at: 2)
            let letter = ns.substring(with: letterRange).uppercased()
            ns.replaceCharacters(in: letterRange, with: letter)
        }
        return ns as String
    }
}
