import Foundation

/// A person the recogniser is expected to encounter by name.
///
/// People are held separately from vocabulary terms and correction rules
/// because they behave differently. A term is a hint and a correction is a rule
/// the user chose; a name, once established, is a fact about the people being
/// spoken about. It should bias the recogniser, rewrite its mis-hearings, and —
/// critically — never be proposed for review a second time.
struct Person: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// The canonical spelling. This is what gets written.
    var name: String
    /// Spellings the recogniser produces for this person. Each becomes a
    /// rewrite rule.
    var aliases: [String] = []
    var note: String = ""
    var enabled: Bool = true
    var addedAt: Date = Date()
    /// Whether the entry came from the analysis pass rather than being typed.
    var learned: Bool = false

    var allSpellings: [String] { [name] + aliases }

    func matches(_ token: String) -> Bool {
        let needle = token.trimmed.lowercased()
        guard !needle.isEmpty else { return false }
        return allSpellings.contains { $0.trimmed.lowercased() == needle }
    }
}

/// On-disk representation of `people.json`.
struct PeopleFile: Codable {
    var version: Int = 1
    var people: [Person] = []
}
