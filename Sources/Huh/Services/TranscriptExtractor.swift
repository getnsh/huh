import Combine
import Foundation
import FoundationModels

/// Reads a transcript in passages and works out what the recogniser got wrong.
///
/// This replaces an earlier approach that sent the model a bare list of
/// unrecognised tokens with one sentence of context each. That approach failed
/// in a specific and predictable way: a small model asked "what is *bundo*?"
/// with nothing to go on invents an answer, and asked the same question about
/// twelve tokens at once it tends to give them all the same answer. It also
/// only ever saw the first handful of tokens in a recording, so most of a long
/// transcript was never examined at all.
///
/// The pass here is built around the model's actual constraint — a 4,096-token
/// context window covering instructions, prompt and response together — rather
/// than around the list of words:
///
///  1. The transcript is divided into passages sized to fit the window with
///     room for the answer, on segment boundaries where they exist.
///  2. Unrecognised tokens are located within each passage by the local
///     detectors, which need no model and are deterministic.
///  3. A passage with no unrecognised tokens is skipped entirely — no request
///     is made, which is what makes reading a whole recording affordable.
///  4. Otherwise the model receives the passage itself alongside its tokens,
///     and classifies each one as a person, a term, a mis-hearing, or unknown.
///
/// The model therefore answers with the surrounding conversation in front of
/// it, which is the only way "Lickup" is recognisable as a person's name.
@MainActor
final class TranscriptExtractor: ObservableObject {

    static let shared = TranscriptExtractor()

    /// A name awaiting confirmation. Accepting one files it in `PeopleStore`,
    /// never in the dictionary.
    struct PersonProposal: Identifiable, Hashable {
        var id: String { heard.lowercased() }
        /// The spelling the recogniser produced.
        var heard: String
        /// The spelling that should be written.
        var name: String
        var context: String
        var timecode: String?

        /// True when the recogniser spelled the name correctly and all that is
        /// being proposed is to remember the person.
        var isSpelledCorrectly: Bool {
            heard.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    @Published private(set) var people: [PersonProposal] = []
    @Published private(set) var passagesRead = 0
    @Published private(set) var passagesTotal = 0

    private init() {}

    var isAvailable: Bool { ModelAvailability.shared.isReady }

    /// Words per passage.
    ///
    /// Small on purpose. The window would accommodate roughly three times this,
    /// but the model reasons visibly better over a passage it can hold at once,
    /// and a short passage keeps the answer anchored to nearby sentences rather
    /// than to something a thousand words away.
    static let wordsPerPassage = 320

    /// Upper bound on tokens asked about in one request. Beyond this the model
    /// starts answering positionally rather than per word.
    static let tokensPerRequest = 8

    // MARK: - Extraction

    struct Result {
        var people: [PersonProposal] = []
        var fixes: [CorrectionSuggester.Proposal] = []
        var passages = 0
        var examined = 0

        var findings: Int { people.count + fixes.count }
    }

    /// Reads one transcript end to end. `stage` reports progress for display.
    func extract(from transcript: Transcript, stage: @escaping (String) -> Void) async -> Result {
        var result = Result()
        let passages = Self.passages(in: transcript)
        result.passages = passages.count
        passagesTotal = passages.count
        passagesRead = 0

        // Tokens are resolved once per transcript, not once per passage: the
        // same name recurs throughout a recording and asking about it in every
        // passage would multiply the cost for no additional information.
        var resolved = Set<String>()

        for (offset, passage) in passages.enumerated() {
            passagesRead = offset + 1
            if passages.count > 1 {
                stage("Reading passage \(offset + 1) of \(passages.count)…")
            } else {
                stage("Reading the transcript…")
            }

            let candidates = Self.unresolvedTokens(in: passage.text, alreadyResolved: resolved)
            guard !candidates.isEmpty else { continue }
            result.examined += candidates.count
            for candidate in candidates { resolved.insert(DecisionLedger.normalise(candidate.word)) }

            guard isAvailable else { continue }

            for batch in candidates.chunked(into: Self.tokensPerRequest) {
                let answers = await classify(batch, in: passage)
                for answer in answers {
                    switch answer.kind {
                    case .person(let name):
                        result.people.append(PersonProposal(
                            heard: answer.token,
                            name: name,
                            context: passage.excerpt(around: answer.token),
                            timecode: passage.timecode
                        ))
                    case .fix(let spelling):
                        result.fixes.append(CorrectionSuggester.Proposal(
                            heard: answer.token,
                            write: spelling,
                            context: passage.excerpt(around: answer.token),
                            warnings: CorrectionSafety.check(hear: answer.token, write: spelling)
                        ))
                    case .term, .skip:
                        continue
                    }
                }
            }
        }

        passagesRead = 0
        passagesTotal = 0
        return result
    }

    /// Merges proposals into the published list, de-duplicated by token, and
    /// never re-surfacing anything already decided.
    func merge(_ incoming: [PersonProposal]) {
        var seen = Set(people.map(\.id))
        let ledger = DecisionLedger.shared
        let store = PeopleStore.shared
        for proposal in incoming {
            guard seen.insert(proposal.id).inserted else { continue }
            guard !ledger.isDecided(proposal.heard) else { continue }
            guard !store.knows(proposal.heard) else { continue }
            people.append(proposal)
        }
    }

    func clear() { people = [] }

    // MARK: - Acting on a proposal

    func accept(_ proposal: PersonProposal) {
        if proposal.isSpelledCorrectly {
            PeopleStore.shared.add(name: proposal.name, learned: true)
        } else {
            PeopleStore.shared.add(name: proposal.name, alias: proposal.heard, learned: true)
        }
        DecisionLedger.shared.record(proposal.heard, decision: .person, resolved: proposal.name)
        people.removeAll { $0.id == proposal.id }
    }

    func dismiss(_ proposal: PersonProposal) {
        DecisionLedger.shared.record(proposal.heard, decision: .ignored)
        people.removeAll { $0.id == proposal.id }
    }

    // MARK: - Passages

    struct Passage {
        var text: String
        var timecode: String?

        /// A short window of the passage around a token, for display next to a
        /// proposal so the user can see where it came from.
        func excerpt(around token: String) -> String {
            guard let range = text.range(of: token, options: .caseInsensitive) else {
                return String(text.prefix(160))
            }
            let start = text.index(range.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
            var out = String(text[start..<end]).trimmed
            if start != text.startIndex { out = "…" + out }
            if end != text.endIndex { out += "…" }
            return out
        }
    }

    /// Divides a transcript into passages, preferring segment boundaries so a
    /// passage never starts mid-sentence.
    static func passages(in transcript: Transcript) -> [Passage] {
        guard !transcript.segments.isEmpty else {
            let words = transcript.text.split(separator: " ")
            guard words.count > wordsPerPassage else {
                return transcript.text.trimmed.isEmpty ? [] : [Passage(text: transcript.text, timecode: nil)]
            }
            return stride(from: 0, to: words.count, by: wordsPerPassage).map { start in
                Passage(
                    text: words[start..<min(start + wordsPerPassage, words.count)].joined(separator: " "),
                    timecode: nil
                )
            }
        }

        var out: [Passage] = []
        var current: [String] = []
        var words = 0
        var timecode: String?

        for segment in transcript.segments {
            if timecode == nil { timecode = segment.timecode }
            let count = segment.text.split(separator: " ").count
            if words + count > wordsPerPassage, !current.isEmpty {
                out.append(Passage(text: current.joined(separator: " "), timecode: timecode))
                current = []
                words = 0
                timecode = segment.timecode
            }
            current.append(segment.text)
            words += count
        }
        if !current.isEmpty {
            out.append(Passage(text: current.joined(separator: " "), timecode: timecode))
        }
        return out
    }

    /// Tokens in a passage that nothing already accounts for.
    ///
    /// The filters here are the reason the same question is never asked twice:
    /// anything in the dictionary, anything in the people store, anything
    /// already decided, and anything resolved earlier in this same pass is gone
    /// before the model is consulted.
    static func unresolvedTokens(
        in text: String,
        alreadyResolved: Set<String>
    ) -> [VocabularySuggester.Candidate] {
        VocabularySuggester.detect(in: text)
            .filter { !alreadyResolved.contains(DecisionLedger.normalise($0.word)) }
    }

    // MARK: - Classification

    private func classify(
        _ candidates: [VocabularySuggester.Candidate],
        in passage: Passage
    ) async -> [ModelReply.Answer] {
        let instructions = Self.instructions(roster: PeopleStore.shared.names)
        let listing = candidates.map(\.word).joined(separator: "\n")

        // Response length scales with the question, with a ceiling: a runaway
        // response consumes the same window the passage is competing for.
        let response = min(300, candidates.count * 14 + 40)
        let allowance = TokenBudget.inputAllowance(instructions: instructions, response: response)
            - TokenBudget.estimate(listing) - 60
        let body = TokenBudget.clip(passage.text, toTokens: max(120, allowance))

        let prompt = """
            Passage:
            \(body)

            Words to decide:
            \(listing)
            """

        guard TokenBudget.fits(instructions: instructions, prompt: prompt, response: response) else {
            Log.app.error("extractor prompt did not fit the window; passage skipped")
            return []
        }

        do {
            // A fresh session per request. Reusing one accumulates every earlier
            // passage in the same window, which is exactly the overflow this
            // design exists to avoid.
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let reply = try await session.respond(to: prompt)
            return ModelReply.classifications(reply.content, candidates: candidates.map(\.word))
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                Log.app.error("extractor overflowed the window despite budgeting")
            }
            return []
        } catch {
            Log.app.error("extractor request failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Kept to a few short paragraphs. Long instructions consume the window the
    /// passage needs and measurably degrade small-model answers.
    static func instructions(roster: [String]) -> String {
        let known = Array(roster.prefix(20))
        let rosterLine = known.isEmpty ? "" : """

            People already known: \(known.joined(separator: ", ")). A misspelling is often one of these.
            """

        return """
            A speech recogniser wrote this passage and could not spell some words. Use the \
            passage to work out what each listed word really is.

            Reply one line per word, exactly: word | KIND | answer

            KIND is one of:
            NAME — a person. Answer with the correct spelling of the name.
            TERM — a real product, company or technical word, already correct. Answer with -
            FIX — an ordinary word heard wrong. Answer with the correct word.
            SKIP — not confident. Answer with -

            Most mistakes are people's names, so consider NAME first. The answer must sound \
            like the word it replaces; if it does not, use SKIP. Never give the same answer \
            for two different words. SKIP is always acceptable and most words should get it. \
            No preamble.\(rosterLine)
            """
    }

}

extension Array {
    /// Fixed-size batches, preserving order.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
