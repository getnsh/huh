import Foundation

/// The two things dictation needs from everything the application has learned:
/// a list of spellings to bias the recogniser toward, and a list of rewrites to
/// apply afterwards.
///
/// Both are assembled here rather than read from `DictionaryStore` directly,
/// because names now live in their own store and dictation must see both
/// sources without either store needing to know the other exists.
@MainActor
enum Rules {

    /// Supplied to the recogniser before it starts. Names lead: they are the
    /// spellings recognition gets wrong most often, and the list is truncated.
    static var bias: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in PeopleStore.shared.biasStrings + DictionaryStore.shared.biasStrings {
            let text = value.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        return Array(out.prefix(DictionaryStore.biasLimit))
    }

    /// Applied to the recogniser's output. The dictionary comes first so a rule
    /// the user wrote by hand wins over one derived from an alias.
    static var corrections: [CorrectionPair] {
        DictionaryStore.shared.corrections + PeopleStore.shared.correctionRules
    }
}
