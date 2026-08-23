import Combine
import Foundation
import FoundationModels

/// Meeting write-ups from Apple's on-device language model.
///
/// Two things worth stating plainly:
///
///  * **`SystemLanguageModel` exclusively.** The same framework also vends
///    `PrivateCloudComputeLanguageModel`, which transmits input to Apple's
///    servers. This file never references it, so the on-device guarantee is
///    enforced by the type system rather than by configuration.
///
///  * **Observe, consolidate, write.** Asking a small model to "summarise" a
///    slice of transcript produces prose that reads well and quietly drops
///    half the content, and asking it to summarise those summaries compounds
///    the loss. So the passes have different jobs. The first extracts labelled
///    observations — topics, decisions, actions, questions, names — which is a
///    copying task rather than a writing one. Those are then deduplicated in
///    ordinary code, where "the same decision stated twice" is a string
///    comparison and not a judgement call. Only the last pass writes anything,
///    and by then it is working from a short, structured list rather than four
///    thousand words.
///
/// Participants are assembled deterministically and never asked for, because a
/// model asked who attended a meeting will supply names.
@MainActor
final class SummaryService: ObservableObject {

    static let shared = SummaryService()

    @Published private(set) var runningFor: UUID?
    /// Nil while the work has no honest percentage. A bar that sits at a made-up
    /// number for a minute is worse than no bar.
    @Published private(set) var progress: Double?
    /// Text as the model writes it, so a long generation is visibly working.
    @Published private(set) var streamed: String = ""
    /// Which model is doing the work, for the caption. It used to claim Apple
    /// unconditionally, which became untrue the moment a second backend existed.
    @Published private(set) var runningEngine: SummaryEngineID = .apple

    /// Set when a transcript is too long for Apple's model to read in one pass
    /// and the choice has not been made yet. The interface presents the options
    /// rather than quietly producing a worse summary.
    @Published var pendingChoice: PendingChoice?

    struct PendingChoice: Identifiable, Equatable {
        var id: UUID { transcript.id }
        var transcript: Transcript
        /// How many separate reads Apple's model would need.
        var pieces: Int
        var words: Int
    }
    @Published private(set) var stage: String = ""
    @Published private(set) var failure: String?

    /// Words per observation pass.
    ///
    /// The window would take roughly twice this. It is kept short because
    /// recall degrades across a long passage well before the window runs out:
    /// a decision made in the last paragraph of a large chunk is the one that
    /// goes missing.
    private let wordsPerChunk = 600

    /// Tokens reserved for each kind of response.
    private let observationTokens = 320
    private let writeUpTokens = 550

    private init() {}

    /// Apple's model needs Apple Intelligence enabled; the downloaded one does
    /// not, so with it selected summaries work on machines that have no Apple
    /// Intelligence at all.
    var isAvailable: Bool {
        AppSettings.shared.summaryEngine == .qwen || ModelAvailability.shared.isReady
    }

    var isRunning: Bool { runningFor != nil }

    func dismissFailure() { failure = nil }

    /// Remembered so the question is asked once, not before every long
    /// transcript.
    static var hasDismissedChoice: Bool {
        get { UserDefaults.standard.bool(forKey: "dismissedSummaryChoice") }
        set { UserDefaults.standard.set(newValue, forKey: "dismissedSummaryChoice") }
    }

    /// Accepts the offer: switch to the local model and summarise. The download
    /// happens inside the run, where its progress is already reported.
    func acceptLocalModel() {
        guard let choice = pendingChoice else { return }
        AppSettings.shared.summaryEngine = .qwen
        run(choice.transcript)
    }

    /// Proceed with Apple's model, in pieces, and stop asking.
    func continueWithApple(remember: Bool) {
        guard let choice = pendingChoice else { return }
        if remember { Self.hasDismissedChoice = true }
        run(choice.transcript)
    }

    func cancelChoice() { pendingChoice = nil }

    // MARK: - Summarise

    /// Whether Apple's model would have to read this transcript in pieces.
    ///
    /// The window is 4,096 tokens for instructions, prompt and response
    /// together, so anything much past a couple of thousand words cannot be
    /// read in one pass. Stitching the pieces together is what loses material,
    /// and it happens silently — which is the reason to say so up front.
    static func piecesRequired(for transcript: Transcript) -> Int {
        let words = transcript.wordCount
        guard words > 0 else { return 1 }
        let chunks = Int(ceil(Double(words) / 600.0))
        return max(1, chunks)
    }

    static func needsPieces(_ transcript: Transcript) -> Bool {
        piecesRequired(for: transcript) > 1
    }

    /// Entry point from the interface. Offers the choice once when it matters,
    /// then gets out of the way.
    func summarise(_ transcript: Transcript) {
        guard runningFor == nil else { return }

        // Also offered when Apple Intelligence is unavailable: the download and
        // the hand-off both work without it, so refusing outright would hide
        // the two routes that would have succeeded.
        if AppSettings.shared.summaryEngine == .apple,
           Self.needsPieces(transcript),
           !Self.hasDismissedChoice || !ModelAvailability.shared.isReady {
            pendingChoice = PendingChoice(
                transcript: transcript,
                pieces: Self.piecesRequired(for: transcript),
                words: transcript.wordCount
            )
            return
        }
        run(transcript)
    }

    /// Proceed with whatever backend is selected, choice already made.
    func run(_ transcript: Transcript) {
        pendingChoice = nil
        guard runningFor == nil, isAvailable else { return }

        runningFor = transcript.id
        progress = 0
        streamed = ""
        runningEngine = AppSettings.shared.summaryEngine
        failure = nil
        stage = "Reading the transcript…"

        Task {
            let started = Date()
            do {
                if AppSettings.shared.summaryEngine == .qwen {
                    try await summariseWholeTranscript(transcript, started: started)
                    runningFor = nil
                    stage = ""
                    return
                }

                let chunks = Self.chunk(transcript, wordsPerChunk: wordsPerChunk)
                Log.app.info("summarise: \(chunks.count, privacy: .public) chunks")

                var observations: [Observation] = []
                for (offset, chunk) in chunks.enumerated() {
                    stage = chunks.count == 1
                        ? "Reading the transcript…"
                        : "Reading part \(offset + 1) of \(chunks.count)…"
                    observations += try await observe(chunk)
                    progress = Double(offset + 1) / Double(chunks.count + 1)
                }

                stage = "Writing it up…"
                let consolidated = Self.consolidate(observations)
                let body = try await writeUp(consolidated)
                let participants = Self.participants(from: consolidated, transcript: transcript)
                progress = 1

                var updated = transcript
                updated.summary = Self.assemble(body: body, participants: participants)
                updated.summaryDate = Date()
                HistoryStore.shared.update(updated)

                Log.app.info("summarise done in \(Date().timeIntervalSince(started), privacy: .public)s")
            } catch {
                failure = Self.readable(error)
                Log.app.error("summarise failed: \(error.localizedDescription, privacy: .public)")
            }
            runningFor = nil
            stage = ""
            streamed = ""
        }
    }

    // MARK: - Whole-transcript path

    /// The downloaded model holds an hour of speech at once, so there is no
    /// chunking, no consolidation and no second pass. Every seam the staged
    /// pipeline has to work around simply does not exist here.
    private func summariseWholeTranscript(_ transcript: Transcript, started: Date) async throws {
        // The model may not be on disk yet. Downloading is the only part of this
        // with a real percentage, so it owns the progress bar; everything after
        // reports what it is doing instead of pretending to measure it.
        let model = LocalLanguageModel.shared
        if !model.isReady {
            progress = nil
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    self?.stage = model.statusText
                    self?.progress = model.state.fraction
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { watch.cancel() }
            _ = try await model.load()
        }

        stage = "Reading the whole meeting…"
        progress = nil

        let body = transcript.segments.isEmpty
            ? transcript.text
            : transcript.segments.map(\.text).joined(separator: " ")

        let roster = PeopleStore.shared.names.prefix(20)
        let rosterHint = roster.isEmpty ? "" : """


            People already known by name: \(roster.joined(separator: ", ")). Prefer these \
            spellings where the transcript is clearly referring to them.
            """

        let instructions = """
            You write up meeting notes from a transcript produced by a speech recogniser. \
            The transcript is imperfect: names may be misspelled and sentences garbled. \
            Work only from what is there. Never invent a name, a date, an owner or a \
            decision, and never assign a task to someone the transcript does not name.\(rosterHint)
            """

        stage = "Writing it up…"
        let text = try await model.respond(
            instructions: instructions,
            prompt: Self.headings + "\n\nTranscript:\n" + body,
            onChunk: { [weak self] partial in
                Task { @MainActor in
                    self?.streamed = partial
                    self?.stage = "Writing it up… \(partial.split(separator: " ").count) words"
                }
            }
        )
        progress = 1

        var updated = transcript
        updated.summary = text
        updated.summaryDate = Date()
        HistoryStore.shared.update(updated)
        Log.app.info("summarise (local model) done in \(Date().timeIntervalSince(started), privacy: .public)s")
    }

    /// Shared by both backends, so the two produce the same shape of document
    /// and can be compared directly.
    static let headings = """
        Use exactly these headings, in this order. If a section has nothing, write \
        "None recorded." under it.

        ## In one line
        One sentence: what this was about and what came of it.

        ## What was discussed
        Three to five short bullets.

        ## Decisions
        Bullets. Only what was actually settled.

        ## Action items
        Bullets formatted "Owner — task". Write "Unassigned" when no owner is named.

        ## Open questions
        Bullets.
        """

    // MARK: - Observations

    typealias Observation = ModelReply.Observation
    typealias ObservationKind = ModelReply.ObservationKind

    private func observe(_ chunk: String) async throws -> [Observation] {
        let instructions = """
            You are reading one part of a meeting transcript. List what this part actually \
            contains. This is a copying task: every line must be supported by the text in \
            front of you.

            One item per line, each starting with one of these labels:
            TOPIC: what was being discussed
            DECISION: something that was settled
            ACTION: who agreed to do what, as "name — task"
            QUESTION: something raised and left open
            PERSON: the name of someone taking part, exactly as spelled in the text

            Skip a label entirely when this part has nothing for it. Invent nothing. \
            No preamble and no other text.
            """

        let allowance = TokenBudget.inputAllowance(instructions: instructions, response: observationTokens) - 40
        let body = TokenBudget.clip(chunk, toTokens: max(200, allowance))

        do {
            let raw = try await run(instructions: instructions, prompt: body, expecting: observationTokens)
            return ModelReply.observations(raw)
        } catch let error as LanguageModelSession.GenerationError {
            // Budgeting is an estimate; halve and retry rather than losing the
            // chunk outright.
            if case .exceededContextWindowSize = error {
                Log.app.info("chunk overflowed the window, splitting")
                let halves = Self.split(body)
                guard halves.count == 2 else { throw error }
                return try await observe(halves[0]) + (try await observe(halves[1]))
            }
            throw error
        }
    }

    // MARK: - Consolidation

    static func consolidate(_ observations: [Observation]) -> [Observation] {
        ModelReply.consolidate(observations)
    }

    /// Names, taken from the observations and cross-checked against the people
    /// store. Nothing here comes from the model's imagination: a name is listed
    /// only if it was written down as a participant, and it is spelled the way
    /// the people store spells it when that store knows them.
    static func participants(from observations: [Observation], transcript: Transcript) -> [String] {
        let store = PeopleStore.shared
        var out: [String] = []
        var seen = Set<String>()

        for observation in observations where observation.kind == .person {
            let name = observation.text
                .components(separatedBy: CharacterSet(charactersIn: ",—-(")).first?.trimmed ?? observation.text
            guard name.count >= 2, name.count <= 40, name.first?.isLetter == true else { continue }
            // Only names that genuinely occur in the transcript.
            guard transcript.text.localizedCaseInsensitiveContains(name) else { continue }
            let canonical = store.people.first { $0.matches(name) }?.name ?? name
            guard seen.insert(canonical.lowercased()).inserted else { continue }
            out.append(canonical)
        }
        return Array(out.prefix(12))
    }

    // MARK: - Write-up

    private func writeUp(_ observations: [Observation]) async throws -> String {
        let instructions = """
            You write up meeting notes from a list of observations someone else took. \
            Everything you write must come from that list. Never add a name, a date, an \
            owner or a decision that is not in it.

            Write plainly and briefly. Prefer the words the observations use.
            """

        var body = ModelReply.format(observations, excluding: [.person])
        let allowance = TokenBudget.inputAllowance(instructions: instructions, response: writeUpTokens) - 200

        // A long recording can produce more observations than the window holds
        // even after deduplication. Condense the list itself before writing,
        // rather than truncating it and silently losing the end of the meeting.
        if TokenBudget.estimate(body) > allowance {
            stage = "Condensing what was found…"
            body = try await condense(observations, toTokens: allowance)
        }

        let prompt = Self.headings + "\n\nObservations:\n" + body

        return try await run(instructions: instructions, prompt: prompt, expecting: writeUpTokens)
    }

    /// Reduces an over-long observation list by condensing it in batches, each
    /// batch sized to the window. The labels survive, so the write-up pass still
    /// receives structure rather than prose.
    private func condense(_ observations: [Observation], toTokens limit: Int) async throws -> String {
        let instructions = """
            Shorten this list of labelled meeting observations. Keep every label. Merge \
            lines that say the same thing and drop lines that say nothing. Change no \
            names and add nothing. Reply with the shortened list only.
            """

        let batchAllowance = TokenBudget.inputAllowance(instructions: instructions, response: observationTokens) - 40
        var kept: [Observation] = []
        var batch: [Observation] = []

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let raw = try await run(
                instructions: instructions,
                prompt: ModelReply.format(batch, excluding: [.person]),
                expecting: observationTokens
            )
            let parsed = ModelReply.observations(raw)
            kept += parsed.isEmpty ? batch : parsed
            batch = []
        }

        for observation in observations where observation.kind != .person {
            batch.append(observation)
            if TokenBudget.estimate(ModelReply.format(batch, excluding: [.person])) > batchAllowance {
                batch.removeLast()
                try await flush()
                batch = [observation]
            }
        }
        try await flush()

        let condensed = ModelReply.format(Self.consolidate(kept), excluding: [.person])
        return TokenBudget.estimate(condensed) > limit
            ? TokenBudget.clip(condensed, toTokens: limit)
            : condensed
    }

    /// Prepends the participant list to the model's write-up. Assembled rather
    /// than generated, for the reason given at the top of this file.
    static func assemble(body: String, participants: [String]) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participants.isEmpty else { return text }
        return """
            ## Who was named
            \(participants.map { "- \($0)" }.joined(separator: "\n"))

            \(text)
            """
    }

    // MARK: - Requests

    private func run(instructions: String, prompt: String, expecting response: Int) async throws -> String {
        guard TokenBudget.fits(instructions: instructions, prompt: prompt, response: response) else {
            throw SummaryError.tooLong
        }
        // A fresh session per request. Reusing one accumulates every previous
        // chunk in the same window, which is exactly what the chunking exists
        // to avoid.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let reply = try await session.respond(to: prompt)
        return reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking

    /// Splits on segment boundaries where they exist, so a chunk never begins
    /// mid-sentence. Timecodes are carried through: an action item is far more
    /// useful when it can be traced back to the moment it was agreed.
    static func chunk(_ transcript: Transcript, wordsPerChunk: Int) -> [String] {
        guard !transcript.segments.isEmpty else {
            return split(transcript.text, targetWords: wordsPerChunk)
        }

        var chunks: [String] = []
        var current: [String] = []
        var words = 0
        for segment in transcript.segments {
            let count = segment.text.split(separator: " ").count
            if words + count > wordsPerChunk, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                words = 0
            }
            current.append(segment.text)
            words += count
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }

    private static func split(_ text: String, targetWords: Int) -> [String] {
        let words = text.split(separator: " ")
        guard words.count > targetWords else { return [text] }
        return stride(from: 0, to: words.count, by: targetWords).map { start in
            words[start..<min(start + targetWords, words.count)].joined(separator: " ")
        }
    }

    private static func split(_ text: String) -> [String] {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return [text] }
        let middle = words.count / 2
        return [words[0..<middle].joined(separator: " "), words[middle...].joined(separator: " ")]
    }

    enum SummaryError: LocalizedError {
        case tooLong
        var errorDescription: String? {
            "That section is too long for the on-device model even after splitting."
        }
    }

    private static func readable(_ error: Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return "That transcript is too long for the on-device model even after splitting."
            case .guardrailViolation:
                return "Apple's on-device model declined to summarise this transcript."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
