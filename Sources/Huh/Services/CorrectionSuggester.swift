import Combine
import Foundation
import FoundationModels

/// Holds correction proposals awaiting review, and resolves a single word on
/// demand.
///
/// Bulk resolution used to live here, asking the model about a list of tokens
/// stripped of their surroundings. That is now `TranscriptExtractor`'s job,
/// which reads the transcript itself; this type keeps the review queue those
/// proposals land in, plus the one-word lookup the correction editor uses when
/// the user has already decided a word is wrong and only wants a suggestion for
/// what to replace it with.
///
/// Every proposal is validated by `CorrectionSafety` before being surfaced,
/// because a wrong proposal for a common word produces a rule that silently
/// rewrites unrelated text. Nothing is ever applied without explicit
/// acceptance.
@MainActor
final class CorrectionSuggester: ObservableObject {

    static let shared = CorrectionSuggester()

    struct Proposal: Identifiable, Hashable {
        var id: String { heard.lowercased() }
        var heard: String
        var write: String
        var context: String
        var warnings: [CorrectionSafety.Warning]

        var isRisky: Bool { warnings.contains { $0.severity == .danger } }
    }

    @Published private(set) var proposals: [Proposal] = []
    @Published private(set) var failure: String?
    @Published private(set) var lastRunFoundNothing = false

    private init() {}

    var isAvailable: Bool { ModelAvailability.shared.isReady }

    func dismissFailure() { failure = nil }

    // MARK: - Queue

    /// Merges proposals into the published list, de-duplicated by token and
    /// filtered against everything already decided.
    func merge(_ incoming: [Proposal]) {
        var seen = Set(proposals.map(\.id))
        let ledger = DecisionLedger.shared
        for proposal in incoming {
            guard seen.insert(proposal.id).inserted else { continue }
            guard !ledger.isDecided(proposal.heard) else { continue }
            proposals.append(proposal)
        }
    }

    func clear() {
        proposals = []
        lastRunFoundNothing = false
    }

    func noteEmptyRun(_ empty: Bool) { lastRunFoundNothing = empty }

    // MARK: - Single-word lookup

    /// Resolves one token. Returns nil when the model declines, which is a
    /// valid outcome rather than an error.
    func suggest(for word: String) async -> String? {
        guard isAvailable else { return nil }
        let context = Self.context(for: word)
        let instructions = Self.singleWordInstructions()
        let prompt = """
            The speech recogniser wrote “\(word)” here:

            \(TokenBudget.clip(context, toTokens: 400))

            What did the speaker actually say? Reply with the corrected spelling alone, \
            or SKIP.
            """

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let reply = try await session.respond(to: prompt)
            return Self.parseSingle(reply.content, for: word)
        } catch {
            Log.app.error("single suggestion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func singleWordInstructions() -> String {
        let roster = knownNames()
        let hint = roster.isEmpty ? "" : "\n\nAlready known, and often the answer: \(roster.joined(separator: ", "))."
        return """
            A speech recogniser produced a word it could not spell. Work out what was said.

            Most such words are people's names, so consider a name first, then a product or \
            company. The answer must sound like the word it replaces. Reply with the \
            spelling alone — no explanation. If you are not confident, reply SKIP.\(hint)
            """
    }

    static func parseSingle(_ raw: String, for word: String) -> String? {
        let first = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .first { !$0.isEmpty } ?? ""
        var value = first.components(separatedBy: CharacterSet(charactersIn: ".;(|")).first?.trimmed ?? first
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—\"'“”"))
        guard !value.isEmpty, value.uppercased() != "SKIP" else { return nil }
        guard value.count <= word.count * 3 + 12, value.first?.isLetter == true else { return nil }
        guard value.compare(word, options: .caseInsensitive) != .orderedSame else { return nil }
        guard EditDistance.isPlausibleCorrection(from: word, to: value) else { return nil }
        return value
    }

    // MARK: - Reference material

    /// Spellings already in use, supplied to the model as a reference list. A
    /// mis-transcribed word is frequently one of them. Capped, because long
    /// reference lists degrade small-model output and consume the window the
    /// prompt needs.
    static func knownNames() -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        // People first: they are both the most common failure and the most
        // useful hint.
        for name in PeopleStore.shared.names {
            let text = name.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        let dictionary = DictionaryStore.shared
        for term in dictionary.terms where term.enabled {
            let text = term.text.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        for pair in dictionary.corrections where pair.enabled {
            let text = pair.write.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        return Array(out.prefix(30))
    }

    /// A passage containing the token, supplied as disambiguating context.
    static func context(for word: String) -> String {
        for transcript in HistoryStore.shared.transcripts {
            if let segment = transcript.segments.first(where: { $0.text.localizedCaseInsensitiveContains(word) }) {
                return segment.text.trimmed
            }
            if let range = transcript.text.range(of: word, options: .caseInsensitive) {
                let text = transcript.text
                let start = text.index(range.lowerBound, offsetBy: -140, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
                return String(text[start..<end]).trimmed
            }
        }
        return word
    }

    // MARK: - Acting on a proposal

    func accept(_ proposal: Proposal) {
        DictionaryStore.shared.addCorrection(hear: proposal.heard, write: proposal.write)
        DecisionLedger.shared.record(proposal.heard, decision: .correction, resolved: proposal.write)
        VocabularySuggester.shared.retire(proposal.heard)
        proposals.removeAll { $0.id == proposal.id }
    }

    /// Files the proposal as a person instead. Offered because the model's
    /// commonest correct answer is a name, and a name belongs in the people
    /// store, where it will not be revised again.
    func acceptAsPerson(_ proposal: Proposal) {
        PeopleStore.shared.add(name: proposal.write, alias: proposal.heard, learned: true)
        DecisionLedger.shared.record(proposal.heard, decision: .person, resolved: proposal.write)
        VocabularySuggester.shared.retire(proposal.heard)
        proposals.removeAll { $0.id == proposal.id }
    }

    func edit(_ proposal: Proposal) {
        UIState.shared.openCorrection(prefilledHear: proposal.heard, write: proposal.write)
        proposals.removeAll { $0.id == proposal.id }
    }

    func dismiss(_ proposal: Proposal) {
        DecisionLedger.shared.record(proposal.heard, decision: .ignored)
        VocabularySuggester.shared.retire(proposal.heard)
        proposals.removeAll { $0.id == proposal.id }
    }
}
