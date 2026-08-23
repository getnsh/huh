import AppKit
import Combine
import Foundation
import NaturalLanguage

/// Locates words the recogniser could not spell.
///
/// This stage deliberately involves no language model. Deciding *which* tokens
/// are suspect requires no world knowledge, only a dictionary and a
/// named-entity tagger, both of which are deterministic, instant, and always
/// available. Deciding what a suspect token was meant to be does require world
/// knowledge, and is `TranscriptExtractor`'s job.
///
/// Two detectors run over the text:
///
///  1. `NSSpellChecker` flags tokens absent from the system dictionary. A token
///     that is not a dictionary word is, in practice, jargon, a product, or a
///     person.
///  2. `NLTagger` named-entity recognition identifies personal names. This is
///     necessary because the spell checker accepts many capitalised unknown
///     tokens as proper nouns, and names are what speech recognisers get wrong
///     most often.
///
/// Anything the dictionary, the people store, or the decision ledger already
/// accounts for is removed before anything is surfaced. That filter is what
/// stops the same word being raised on every pass.
@MainActor
final class VocabularySuggester: ObservableObject {

    static let shared = VocabularySuggester()

    struct Candidate: Identifiable, Hashable {
        var id: String { word.lowercased() }
        var word: String
        var count: Int
        /// Personal names are ranked first and annotated when passed onward.
        var isName: Bool = false
    }

    /// Unrecognised words, excluding personal names. Reviewed on the Words tab
    /// and, if accepted, added to the dictionary.
    @Published private(set) var candidates: [Candidate] = []
    /// Personal names, reviewed on the People tab and, if accepted, filed in
    /// `PeopleStore`.
    ///
    /// Held apart from `candidates` rather than flagged within it. A name and a
    /// piece of jargon look alike to a detector but are different things to the
    /// person reviewing them, and they end up in different stores — offering
    /// them in one list invited filing a colleague as vocabulary. Separate caps
    /// also stop either kind crowding the other out of a single short list.
    @Published private(set) var nameCandidates: [Candidate] = []
    /// Candidates withheld solely because they were previously rejected.
    /// Distinguishes "nothing found" from "everything found was dismissed";
    /// only the latter is recoverable.
    @Published private(set) var suppressedCount = 0

    /// Minimum corpus-wide occurrences before a token is offered for review.
    ///
    /// Two rather than three: a single occurrence across a whole corpus is
    /// usually noise, but requiring three suppresses most mis-transcribed proper
    /// nouns, which appear once or twice per recording.
    private let threshold = 2
    private let maxSuggestions = 8
    private let maxNames = 8

    private var cancellables = Set<AnyCancellable>()

    private init() {
        HistoryStore.shared.$transcripts
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        DictionaryStore.shared.$terms
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        PeopleStore.shared.$people
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh() {
        let transcripts = HistoryStore.shared.transcripts
        guard !transcripts.isEmpty else {
            candidates = []
            nameCandidates = []
            suppressedCount = 0
            return
        }
        let (found, suppressed) = Self.scan(transcripts, threshold: threshold)
        candidates = Array(found.filter { !$0.isName }.prefix(maxSuggestions))
        nameCandidates = Array(found.filter(\.isName).prefix(maxNames))
        suppressedCount = suppressed
    }

    // MARK: - Detection

    /// Everything unaccounted for in a single piece of text.
    ///
    /// Used by `TranscriptExtractor` on one passage at a time, where a threshold
    /// above one would discard almost every true positive: within a few hundred
    /// words a mis-transcribed name appears exactly once.
    static func detect(in text: String) -> [Candidate] {
        scan([Transcript(raw: text, text: text)], threshold: 1).found
    }

    /// Spellings that nothing needs to ask about, from every store that holds
    /// an answer.
    static func accountedFor() -> Set<String> {
        let dictionary = DictionaryStore.shared
        var known = Set(dictionary.terms.map { $0.text.lowercased() })
        known.formUnion(dictionary.corrections.map { $0.write.lowercased() })
        known.formUnion(dictionary.corrections.map { $0.hear.lowercased() })
        for person in PeopleStore.shared.people {
            known.formUnion(person.allSpellings.map { $0.trimmed.lowercased() })
        }
        known.formUnion(DecisionLedger.shared.records.keys)
        return known
    }

    /// Token counting runs over all supplied transcripts; the spell check runs
    /// only on tokens above the threshold, since it is the costlier operation.
    static func scan(_ transcripts: [Transcript], threshold: Int) -> (found: [Candidate], suppressed: Int) {
        var counts: [String: (display: String, count: Int)] = [:]
        for transcript in transcripts {
            for raw in transcript.text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }) {
                let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
                guard word.count >= 3, word.count <= 24, word.first?.isLetter == true else { continue }
                let key = word.lowercased()
                counts[key] = (counts[key]?.display ?? word, (counts[key]?.count ?? 0) + 1)
            }
        }

        let known = accountedFor()
        let ledger = DecisionLedger.shared

        let overThreshold = counts
            .filter { $0.value.count >= threshold }
            .filter { !known.contains($0.key) }

        // The language parameter is required.
        //
        // `checkSpelling(of:startingAt:)` relies on automatic language
        // identification, which cannot resolve a language from a single token in
        // isolation and consequently reports almost every input as correctly
        // spelled. Supplying an explicit language produces correct results.
        let checker = NSSpellChecker.shared
        let language = AppSettings.shared.locale.language.languageCode?.identifier ?? "en"

        var found: [Candidate] = []
        for (_, value) in overThreshold {
            let range = checker.checkSpelling(
                of: value.display,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            guard range.location != NSNotFound else { continue }   // a real word
            found.append(Candidate(word: value.display, count: value.count))
        }

        // Second detector: personal names. `NLTagger` uses surrounding context,
        // so a mis-transcribed name is still identified as a name even when its
        // spelling is meaningless.
        var nameCounts: [String: (display: String, count: Int)] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        for transcript in transcripts {
            let text = transcript.text
            guard !text.isEmpty else { continue }
            tagger.string = text
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: [.omitPunctuation, .omitWhitespace, .joinNames]
            ) { tag, range in
                guard tag == .personalName else { return true }
                let name = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
                guard name.count >= 3, name.count <= 24, name.first?.isLetter == true else { return true }
                let key = name.lowercased()
                guard !known.contains(key) else { return true }
                nameCounts[key] = (nameCounts[key]?.display ?? name, (nameCounts[key]?.count ?? 0) + 1)
                return true
            }
        }

        var seenWords = Set(found.map(\.id))
        for (_, value) in nameCounts where value.count >= 1 {
            let candidate = Candidate(word: value.display, count: value.count, isName: true)
            if seenWords.insert(candidate.id).inserted {
                found.append(candidate)
            } else if let index = found.firstIndex(where: { $0.id == candidate.id }) {
                found[index].isName = true
            }
        }

        // Count rejected candidates so the interface can offer to restore them.
        var suppressed = 0
        for (key, value) in counts where value.count >= threshold {
            guard ledger.decision(for: key)?.decision == .ignored else { continue }
            let range = checker.checkSpelling(
                of: value.display, startingAt: 0, language: language,
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            if range.location != NSNotFound { suppressed += 1 }
        }

        // Personal names rank first: they are the least reliably transcribed.
        let ranked = found.sorted {
            if $0.isName != $1.isName { return $0.isName }
            return ($0.count, $1.word) > ($1.count, $0.word)
        }
        return (ranked, suppressed)
    }

    // MARK: - Acting on a candidate

    func accept(_ candidate: Candidate) {
        DictionaryStore.shared.addTerm(candidate.word)
        DecisionLedger.shared.record(candidate.word, decision: .term, resolved: candidate.word)
        remove(candidate.id)
    }

    /// Files the candidate as a person instead of a dictionary term. Names live
    /// in their own store because, once settled, they should never move again.
    func acceptAsPerson(_ candidate: Candidate) {
        PeopleStore.shared.add(name: candidate.word, learned: true)
        DecisionLedger.shared.record(candidate.word, decision: .person, resolved: candidate.word)
        remove(candidate.id)
    }

    func dismiss(_ candidate: Candidate) {
        DecisionLedger.shared.record(candidate.word, decision: .ignored)
        remove(candidate.id)
    }

    /// Removes a token from the review list without recording a decision. Used
    /// when the decision is recorded elsewhere, such as by accepting a
    /// correction proposal for the same token.
    func retire(_ word: String) {
        remove(DecisionLedger.normalise(word))
    }

    /// A token appears in exactly one of the two lists, but which one depends on
    /// a detector, so removal always addresses both.
    private func remove(_ id: String) {
        candidates.removeAll { $0.id == id }
        nameCandidates.removeAll { $0.id == id }
    }

    func resetDismissed() {
        DecisionLedger.shared.restoreIgnored()
        refresh()
    }
}
