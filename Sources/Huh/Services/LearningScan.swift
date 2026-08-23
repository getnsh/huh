import Combine
import Foundation

/// Reads each transcript exactly once and records that it has done so.
///
/// A durable queue rather than a periodic sweep. Per-transcript state is
/// persisted, which makes progress visible in the interface, resumable after
/// termination, and idempotent across launches.
///
/// Ordering matters: a transcript is persisted first and queued second, so
/// transcription latency never depends on the language model being available.
/// The queue is processed newest first.
///
/// Nothing here decides anything. The pass produces proposals; every one of them
/// waits for a person. What it does guarantee is that a question is asked at
/// most once — `DecisionLedger` holds the answer to every question already put,
/// and a manual rescan re-reads unread transcripts rather than wiping the record
/// and starting over.
@MainActor
final class LearningScan: ObservableObject {

    static let shared = LearningScan()

    /// The transcript being read right now, if any.
    @Published private(set) var analysing: UUID?
    @Published private(set) var pending: Int = 0
    @Published private(set) var stage = ""
    /// Result of an explicitly requested scan. Automatic passes report nothing.
    @Published var result: String?

    private var queueTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        HistoryStore.shared.$transcripts
            .map { $0.filter { $0.analyzedAt == nil }.count }
            .removeDuplicates()
            .sink { [weak self] count in self?.pending = count }
            .store(in: &cancellables)
    }

    var isRunning: Bool { analysing != nil }

    /// Suggestions currently awaiting a decision.
    var pendingCount: Int {
        TranscriptExtractor.shared.people.count
            + CorrectionSuggester.shared.proposals.count
            + VocabularySuggester.shared.candidates.count
    }

    func dismissResult() { result = nil }

    var canRestoreDismissed: Bool { DecisionLedger.shared.ignoredCount > 0 }

    func restoreDismissed() {
        DecisionLedger.shared.restoreIgnored()
        VocabularySuggester.shared.refresh()
        runManually()
    }

    // MARK: - Automatic queue

    /// Invoked when a transcript is added, and once at launch to clear any
    /// backlog. Termination mid-pass must not lose work.
    func scheduleQueue() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            // Brief delay so the interface finishes updating first.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await self?.drainQueue()
            self?.queueTask = nil
        }
    }

    private func drainQueue() async {
        // Without the model a transcript cannot be read, and marking it read
        // anyway would mean it is never looked at once the model arrives. The
        // backlog is left standing instead, and reported as such.
        guard TranscriptExtractor.shared.isAvailable else {
            VocabularySuggester.shared.refresh()
            return
        }
        while let next = HistoryStore.shared.pendingAnalysis.first {
            await analyse(next)
        }
        VocabularySuggester.shared.refresh()
    }

    private func analyse(_ transcript: Transcript) async {
        analysing = transcript.id
        let label = transcript.source == .file ? transcript.sourceName : "your dictation"
        stage = "Reading \(label)…"
        defer { analysing = nil; stage = "" }

        let extractor = TranscriptExtractor.shared
        let result = await extractor.extract(from: transcript) { [weak self] message in
            self?.stage = message
        }

        extractor.merge(result.people)
        CorrectionSuggester.shared.merge(result.fixes)

        // Findings counts what a person now has to look at, not tokens
        // examined; reporting the latter would overstate what the pass found.
        HistoryStore.shared.markAnalysed(transcript.id, findings: result.findings)
        VocabularySuggester.shared.refresh()
        Log.app.info("read transcript: \(result.passages, privacy: .public) passages, \(result.examined, privacy: .public) words examined, \(result.findings, privacy: .public) findings")
    }

    // MARK: - Manual

    /// Explicit rescan, reporting the outcome.
    ///
    /// Reads transcripts that have not been read, and re-surfaces anything still
    /// undecided. It deliberately does not clear the analysis marks: doing so
    /// re-asked every question that had already been answered, which is the one
    /// behaviour a review queue must never have.
    func runManually() {
        guard !isRunning else { return }
        guard !HistoryStore.shared.transcripts.isEmpty else {
            result = "Nothing to learn from yet — dictate or transcribe something first."
            return
        }
        result = nil

        Task {
            await drainQueue()

            let names = TranscriptExtractor.shared.people.count
            let fixes = CorrectionSuggester.shared.proposals.count
            let words = VocabularySuggester.shared.candidates.count
            CorrectionSuggester.shared.noteEmptyRun(fixes == 0)

            let ui = UIState.shared
            ui.section = .dictionary
            if names > 0 {
                ui.dictionaryTab = .people
            } else if fixes > 0 {
                ui.dictionaryTab = .corrections
            } else {
                ui.dictionaryTab = .terms
            }

            result = Self.describe(
                names: names,
                fixes: fixes,
                words: words,
                unread: HistoryStore.shared.pendingAnalysis.count,
                dismissed: DecisionLedger.shared.ignoredCount
            )
        }
    }

    /// Distinguishes "nothing was found" from "everything found was already
    /// answered"; only the second is recoverable, and saying so is the
    /// difference between a useful message and a confusing one.
    private static func describe(names: Int, fixes: Int, words: Int, unread: Int, dismissed: Int) -> String {
        var parts: [String] = []
        if names > 0 { parts.append("\(names) name\(names == 1 ? "" : "s")") }
        if fixes > 0 { parts.append("\(fixes) suggested fix\(fixes == 1 ? "" : "es")") }
        if words > 0 { parts.append("\(words) unfamiliar word\(words == 1 ? "" : "s")") }

        if !parts.isEmpty {
            return parts.joined(separator: ", ") + " to review."
        }
        if unread > 0 {
            return "\(unread) transcript\(unread == 1 ? "" : "s") couldn't be read — Apple Intelligence isn't available."
        }
        if dismissed > 0 {
            return "Nothing new. \(dismissed) suggestion\(dismissed == 1 ? " is" : "s are") hidden because you dismissed \(dismissed == 1 ? "it" : "them")."
        }
        return "Nothing new — every transcript has been read and everything in them is already known."
    }
}
