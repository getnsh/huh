import Combine
import Foundation
import FoundationModels

/// Questions and answers over a single transcript.
///
/// The obvious implementation — hand the model the transcript and let the user
/// ask — cannot work: a transcript of any length is many times the model's
/// 4,096-token window, and a session that overflows stops answering entirely.
/// So each question retrieves the passages that bear on it and sends only
/// those, which is Apple's documented approach for exactly this case.
///
/// Retrieval is lexical rather than vector-based: scoring by inverse document
/// frequency over the transcript's own passages needs no embedding model, no
/// prepared index and no download, and over a few thousand words it locates the
/// relevant minute reliably. Passages keep their timecodes, so an answer can
/// point at where it came from.
///
/// Two guards keep answers honest. If nothing in the transcript matches the
/// question at all, no request is made. If the model is given passages and they
/// do not contain the answer, it is instructed to say so in a form this code
/// recognises and replaces with a plain admission — which is the correct
/// outcome for a local model working from one recording, and much better than a
/// confident invention.
@MainActor
final class TranscriptChat: ObservableObject {

    static let shared = TranscriptChat()

    enum Role: String, Codable { case you, app }

    struct Message: Identifiable, Hashable {
        var id = UUID()
        var role: Role
        var text: String
        /// Timecodes of the passages the answer drew on.
        var sources: [String] = []
        /// Set when the answer is the out-of-scope admission, so the interface
        /// can present it as an explanation rather than a failure.
        var isOutOfScope = false
    }

    /// Threads are keyed by transcript and held in memory only. A conversation
    /// about a recording is a working aid, not a document; persisting it would
    /// mean a second store of the user's speech for no benefit they asked for.
    @Published private(set) var threads: [UUID: [Message]] = [:]
    @Published private(set) var thinking: UUID?
    @Published var draft = ""

    private init() {}

    var isAvailable: Bool { ModelAvailability.shared.isReady }

    func messages(for transcript: UUID) -> [Message] { threads[transcript] ?? [] }

    func isThinking(about transcript: UUID) -> Bool { thinking == transcript }

    func clear(_ transcript: UUID) { threads[transcript] = [] }

    /// Shown when nothing in the transcript bears on the question. Phrased as
    /// what it is: a small local model with one recording in front of it.
    static let outOfScope = """
        Sorry — that's all the context I could grab. I'm a local model working only from \
        this transcript, so anything outside it I genuinely don't know.
        """

    /// Suggested openers, so the field is not a blank prompt.
    static func starters(for transcript: Transcript) -> [String] {
        var out = ["What was decided?", "What did I agree to do?"]
        if !transcript.segments.isEmpty { out.append("Who was talking about what?") }
        out.append("What was left unresolved?")
        return out
    }

    // MARK: - Asking

    func ask(_ question: String, about transcript: Transcript) {
        let text = question.trimmed
        guard !text.isEmpty, thinking == nil else { return }
        guard isAvailable else { return }

        append(Message(role: .you, text: text), to: transcript.id)
        draft = ""
        thinking = transcript.id

        Task {
            let answer = await answer(text, about: transcript)
            append(answer, to: transcript.id)
            thinking = nil
        }
    }

    private func append(_ message: Message, to id: UUID) {
        threads[id, default: []].append(message)
    }

    private func answer(_ question: String, about transcript: Transcript) async -> Message {
        let passages = Self.retrieve(question, from: transcript)

        // Nothing in the recording touches the question. Answer without asking.
        guard !passages.isEmpty else {
            return Message(role: .app, text: Self.outOfScope, isOutOfScope: true)
        }

        let instructions = Self.instructions()
        let history = Self.recentExchange(threads[transcript.id] ?? [])
        let excerpts = Self.assembleExcerpts(
            passages,
            summary: transcript.summary,
            allowance: TokenBudget.inputAllowance(instructions: instructions, response: Self.answerTokens)
                - TokenBudget.estimate(history) - TokenBudget.estimate(question) - 80
        )

        let prompt = """
            \(history)Excerpts from the transcript:
            \(excerpts.text)

            Question: \(question)
            """

        guard TokenBudget.fits(instructions: instructions, prompt: prompt, response: Self.answerTokens) else {
            return Message(role: .app, text: Self.outOfScope, isOutOfScope: true)
        }

        do {
            // A fresh session per question, with the recent exchange restated in
            // the prompt. A persistent session would accumulate every excerpt
            // from every previous question and overflow within a few turns.
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let reply = try await session.respond(to: prompt)
            let content = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)

            if Self.isRefusal(content) {
                return Message(role: .app, text: Self.outOfScope, isOutOfScope: true)
            }
            return Message(role: .app, text: content, sources: excerpts.timecodes)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                Log.app.error("chat overflowed the window despite budgeting")
                return Message(role: .app, text: Self.outOfScope, isOutOfScope: true)
            }
            return Message(role: .app, text: Self.readable(error), isOutOfScope: false)
        } catch {
            return Message(role: .app, text: Self.readable(error), isOutOfScope: false)
        }
    }

    static let answerTokens = 400

    // MARK: - Prompting

    static func instructions() -> String {
        """
        You are the assistant inside huh?, an on-device dictation and transcription app \
        made by getnsh. You run on this Mac using Apple's on-device model — nothing said \
        here leaves the machine.

        You answer questions about one transcript, using only the excerpts you are given. \
        Be brief: a few sentences, or short bullets. Use the names and words the transcript \
        uses. You may also answer questions about huh? itself from the description above.

        If the excerpts do not contain the answer, reply with exactly NO_CONTEXT and \
        nothing else. Never guess, and never use knowledge from outside the excerpts.
        """
    }

    /// The last exchange only. Enough for "and what about the second one?" to
    /// resolve, short enough not to displace the excerpts, which are what
    /// actually answer the question.
    static func recentExchange(_ messages: [Message]) -> String {
        let recent = messages.suffix(3).filter { !$0.isOutOfScope }
        guard let question = recent.last(where: { $0.role == .you }),
              let answer = recent.last(where: { $0.role == .app }) else { return "" }
        return """
            Earlier in this conversation:
            Q: \(TokenBudget.clip(question.text, toTokens: 60))
            A: \(TokenBudget.clip(answer.text, toTokens: 120))

            """
    }

    static func isRefusal(_ text: String) -> Bool {
        let upper = text.uppercased()
        guard upper.contains("NO_CONTEXT") else { return false }
        // Only a bare refusal counts. A real answer that happens to mention the
        // token should not be thrown away.
        return text.count < 60
    }

    // MARK: - Retrieval

    struct Passage: Hashable {
        var text: String
        var start: TimeInterval?

        var timecode: String? {
            guard let start else { return nil }
            let total = Int(start.rounded())
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
    }

    /// Words per retrievable passage. Short enough that a hit is precise,
    /// long enough to carry the sentence around it.
    static let wordsPerPassage = 110
    /// Most passages sent for one question.
    static let maxPassages = 8

    static func retrieve(_ question: String, from transcript: Transcript) -> [Passage] {
        let passages = self.passages(in: transcript)
        guard !passages.isEmpty else { return [] }

        let asked = Set(SearchIndex.tokenise(question)).subtracting(stopWords)
        guard !asked.isEmpty else { return spread(passages) }

        // Expand the question before scoring.
        //
        // "What was decided?" is a question about meaning, and a lexical index
        // answers questions about words. Meetings almost never contain the word
        // "decided" -- people say "let's go with", "that works", "we'll do
        // that" -- so the literal term matches nothing and the honest-looking
        // result is a refusal on the one question everybody asks first.
        // Related terms carry less weight than the word actually typed.
        var weights: [String: Double] = [:]
        for term in asked {
            weights[term] = 1
            for related in expansions[term] ?? [] where weights[related] == nil {
                weights[related] = relatedWeight
            }
        }
        let terms = Set(weights.keys)

        // Inverse document frequency, so a word appearing in every passage
        // contributes nothing and a rare one dominates. This is what makes a
        // name or a product the deciding term in a question containing one.
        var frequency: [String: Int] = [:]
        var tokenised: [Set<String>] = []
        for passage in passages {
            let tokens = Set(SearchIndex.tokenise(passage.text))
            tokenised.append(tokens)
            for token in tokens.intersection(terms) { frequency[token, default: 0] += 1 }
        }

        let total = Double(passages.count)
        var scored: [(index: Int, score: Double)] = []
        for (index, tokens) in tokenised.enumerated() {
            var score = 0.0
            for term in terms where tokens.contains(term) {
                let hits = Double(frequency[term] ?? 1)
                score += log(1 + total / hits) * (weights[term] ?? 1)
            }
            // Partial credit for a prefix match, so "decid" finds "decided".
            // Both sides need a real length: without the floor, a two-letter
            // token matched the prefix of almost any word.
            for term in terms where !tokens.contains(term) && term.count >= 5 {
                let near = tokens.contains {
                    $0.count >= 4 && ($0.hasPrefix(term) || term.hasPrefix($0))
                }
                if near { score += 0.4 * (weights[term] ?? 1) }
            }
            if score > 0 { scored.append((index, score)) }
        }

        // Nothing matched. Send a spread of the recording rather than refusing.
        //
        // A miss here means retrieval failed, which is not the same as the
        // recording having no answer -- and only the model can tell those
        // apart. It is instructed to admit when the excerpts fall short, so the
        // worst case is the same refusal arrived at honestly.
        guard !scored.isEmpty else { return spread(passages) }
        scored.sort { $0.score > $1.score }

        // Restore chronological order: an answer assembled from passages in
        // relevance order reads as though the meeting happened backwards.
        return scored
            .prefix(maxPassages)
            .map(\.index)
            .sorted()
            .map { passages[$0] }
    }

    /// An even spread across the whole recording, used when retrieval has
    /// nothing to go on. Sampling beats taking the opening: decisions and
    /// commitments cluster at the end of a meeting, not the start.
    static func spread(_ passages: [Passage]) -> [Passage] {
        guard passages.count > maxPassages else { return passages }
        let step = Double(passages.count) / Double(maxPassages)
        return (0..<maxPassages).map { passages[min(passages.count - 1, Int(Double($0) * step))] }
    }

    /// Weight given to a term the asker did not type. Below the weight of a
    /// literal match, so a passage containing the actual word still wins.
    static let relatedWeight = 0.55

    /// Words that mean one thing to someone asking a question and another to an
    /// index. Every member of a cluster retrieves the rest.
    static let synonymClusters: [[String]] = [
        ["decided", "decide", "decision", "decisions", "agreed", "agree",
         "settled", "confirmed", "conclusion", "concluded"],
        ["action", "actions", "task", "tasks", "todo", "assigned", "owner",
         "responsible", "deadline", "deliverable"],
        ["blocker", "blockers", "blocked", "blocking", "stuck", "issue",
         "issues", "problem", "problems", "risk", "risks"],
        ["next", "steps", "followup", "upcoming", "afterwards", "plan", "plans"],
        ["concern", "concerns", "worried", "worry", "unresolved", "open"],
        ["timeline", "schedule", "date", "dates", "when", "week", "month"]
    ]

    static let expansions: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for cluster in synonymClusters {
            let all = Set(cluster)
            for word in cluster {
                out[word, default: []].formUnion(all.subtracting([word]))
            }
        }
        return out
    }()

    static func passages(in transcript: Transcript) -> [Passage] {
        guard !transcript.segments.isEmpty else {
            let words = transcript.text.split(separator: " ")
            guard !words.isEmpty else { return [] }
            return stride(from: 0, to: words.count, by: wordsPerPassage).map { start in
                Passage(
                    text: words[start..<min(start + wordsPerPassage, words.count)].joined(separator: " "),
                    start: nil
                )
            }
        }

        var out: [Passage] = []
        var current: [String] = []
        var words = 0
        var start: TimeInterval?

        for segment in transcript.segments {
            if start == nil { start = segment.start }
            let count = segment.text.split(separator: " ").count
            if words + count > wordsPerPassage, !current.isEmpty {
                out.append(Passage(text: current.joined(separator: " "), start: start))
                current = []
                words = 0
                start = segment.start
            }
            current.append(segment.text)
            words += count
        }
        if !current.isEmpty { out.append(Passage(text: current.joined(separator: " "), start: start)) }
        return out
    }

    /// Packs passages into the token allowance, most relevant retained, and
    /// includes the summary when one exists — it is the cheapest possible
    /// answer to "what was this about".
    static func assembleExcerpts(
        _ passages: [Passage],
        summary: String,
        allowance: Int
    ) -> (text: String, timecodes: [String]) {
        var remaining = max(200, allowance)
        var parts: [String] = []
        var timecodes: [String] = []

        if !summary.isEmpty {
            let clipped = TokenBudget.clip(summary, toTokens: min(400, remaining / 3))
            parts.append("Summary of the recording:\n\(clipped)")
            remaining -= TokenBudget.estimate(clipped)
        }

        for passage in passages {
            let label = passage.timecode.map { "[\($0)] " } ?? ""
            let entry = label + passage.text
            let cost = TokenBudget.estimate(entry)
            guard cost <= remaining else { continue }
            parts.append(entry)
            remaining -= cost
            if let code = passage.timecode { timecodes.append(code) }
        }

        return (parts.joined(separator: "\n\n"), timecodes)
    }

    /// Words carried by almost every question, which would otherwise dominate
    /// retrieval and return the whole transcript.
    static let stopWords: Set<String> = [
        "the", "and", "was", "were", "what", "who", "when", "where", "why", "how",
        "did", "does", "do", "is", "are", "about", "that", "this", "there", "they",
        "them", "with", "from", "for", "you", "your", "our", "his", "her", "any",
        "all", "can", "could", "would", "should", "have", "has", "had", "been",
        "say", "said", "tell", "give", "get", "got", "just", "some", "into", "than",
        "then", "which", "whom", "whose", "over", "much", "many", "more", "most"
    ]

    private static func readable(_ error: Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError,
           case .guardrailViolation = generation {
            return "Apple's on-device model declined to answer that one."
        }
        return error.localizedDescription
    }
}
