import Foundation

/// Normalised Levenshtein distance, used to reject implausible corrections.
///
/// A proposed correction must plausibly sound like the token it replaces. Small
/// language models supplied with a reference list will confidently map unrelated
/// tokens onto a listed term; edit distance rejects those results structurally
/// rather than relying on the model to behave.
///
/// Pure and dependency-free so it can be exercised directly by the test suite.
enum EditDistance {

    /// Returns 0 for identical strings and 1 for strings with nothing in common.
    /// Comparison is case-insensitive.
    static func normalised(_ a: String, _ b: String) -> Double {
        let lhs = Array(a.lowercased())
        let rhs = Array(b.lowercased())
        guard !lhs.isEmpty, !rhs.isEmpty else { return 1 }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    /// Maximum normalised distance for a correction to be considered plausible.
    /// Calibrated against real recogniser output: genuine mis-transcriptions of
    /// a term score below 0.35, while unrelated substitutions score above 0.7.
    static let plausibilityThreshold = 0.5

    static func isPlausibleCorrection(from heard: String, to write: String) -> Bool {
        normalised(heard, write) <= plausibilityThreshold
    }
}
