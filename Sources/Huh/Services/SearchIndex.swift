import Combine
import Foundation

/// Full-text search across all stored transcripts.
///
/// Implemented as an inverted index rather than a linear scan. A substring scan
/// is adequate for a handful of transcripts but degrades badly at the store's
/// capacity; tokenising once and intersecting posting lists keeps query latency
/// constant as history grows.
///
/// The index is held in memory and rebuilt whenever history changes. No network
/// access is involved.
@MainActor
final class SearchIndex: ObservableObject {

    static let shared = SearchIndex()

    struct Snippet: Identifiable {
        var id = UUID()
        var start: TimeInterval?
        var text: String
        var timecode: String? {
            guard let start else { return nil }
            let total = Int(start.rounded())
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
    }

    struct Hit: Identifiable {
        var id: UUID { transcript.id }
        var transcript: Transcript
        var score: Int
        var snippets: [Snippet]
    }

    @Published private(set) var isReady = false

    private var index: [String: Set<UUID>] = [:]
    private var byID: [UUID: Transcript] = [:]
    private var cancellable: AnyCancellable?

    private init() {
        rebuild(HistoryStore.shared.transcripts)
        cancellable = HistoryStore.shared.$transcripts
            .sink { [weak self] transcripts in self?.rebuild(transcripts) }
    }

    // MARK: - Index

    func rebuild(_ transcripts: [Transcript]) {
        var index: [String: Set<UUID>] = [:]
        var byID: [UUID: Transcript] = [:]
        for transcript in transcripts {
            byID[transcript.id] = transcript
            for token in Self.tokenise(transcript.text) {
                index[token, default: []].insert(transcript.id)
            }
            if !transcript.sourceName.isEmpty {
                for token in Self.tokenise(transcript.sourceName) {
                    index[token, default: []].insert(transcript.id)
                }
            }
        }
        self.index = index
        self.byID = byID
        isReady = true
    }

    static func tokenise(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    // MARK: - Query

    func search(_ query: String) -> [Hit] {
        let terms = Self.tokenise(query)
        guard !terms.isEmpty else {
            return HistoryStore.shared.transcripts.map { Hit(transcript: $0, score: 0, snippets: []) }
        }

        // The final term is matched by prefix so results update as the query
        // is typed.
        var candidates: Set<UUID>?
        for (offset, term) in terms.enumerated() {
            let isLast = offset == terms.count - 1
            var matches: Set<UUID> = []
            if isLast {
                for (token, ids) in index where token.hasPrefix(term) {
                    matches.formUnion(ids)
                }
            } else {
                matches = index[term] ?? []
            }
            candidates = candidates.map { $0.intersection(matches) } ?? matches
            if candidates?.isEmpty == true { return [] }
        }

        let phrase = query.trimmed
        return (candidates ?? [])
            .compactMap { byID[$0] }
            .map { transcript in
                let snippets = Self.snippets(in: transcript, matching: phrase, terms: terms)
                // Rank by density of matches within the transcript.
                let score = snippets.count * 10 + transcript.text.lowercased()
                    .components(separatedBy: terms[0]).count - 1
                return Hit(transcript: transcript, score: score, snippets: snippets)
            }
            .sorted { ($0.score, $0.transcript.date) > ($1.score, $1.transcript.date) }
    }

    /// Prefers timecoded segments: for a long recording, identifying the
    /// containing transcript alone is not a useful result.
    private static func snippets(in transcript: Transcript, matching phrase: String, terms: [String]) -> [Snippet] {
        let needle = phrase.isEmpty ? terms[0] : phrase

        if !transcript.segments.isEmpty {
            return transcript.segments
                .filter { segment in
                    segment.text.localizedCaseInsensitiveContains(needle)
                        || terms.allSatisfy { segment.text.localizedCaseInsensitiveContains($0) }
                }
                .prefix(6)
                .map { Snippet(start: $0.start, text: $0.text) }
        }

        guard let range = transcript.text.range(of: needle, options: .caseInsensitive) else { return [] }
        let text = transcript.text
        let start = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[start..<end])
        if start != text.startIndex { excerpt = "…" + excerpt }
        if end != text.endIndex { excerpt += "…" }
        return [Snippet(start: nil, text: excerpt)]
    }
}
