import Foundation

/// A term the recogniser should be biased toward producing.
struct VocabularyTerm: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    var note: String = ""
    var enabled: Bool = true
}

/// A substitution rule: when the recogniser produces `hear`, write `write`.
struct CorrectionPair: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// The text the recogniser produces.
    var hear: String
    /// The text that should replace it.
    var write: String
    var enabled: Bool = true
    /// Number of times this rule has fired, so ineffective entries are
    /// identifiable.
    var hitCount: Int = 0
}

/// On-disk representation. Two flat arrays with stable key ordering and pretty
/// printing, so the file remains readable and editable by hand.
struct DictionaryFile: Codable {
    var version: Int = 1
    var terms: [VocabularyTerm] = []
    var corrections: [CorrectionPair] = []
}
