import AppKit
import Combine
import Foundation

/// Persisted transcript history.
///
/// Bounded rather than unbounded. The store is a working log rather than an
/// archive, and the write cost of the whole file after every utterance grows
/// linearly with its size.
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var transcripts: [Transcript] = []

    static let capacity = 500

    private init() { load() }

    func add(_ transcript: Transcript) {
        Log.app.info("history add: \(transcript.text.count, privacy: .public) chars, \(transcript.corrections.count, privacy: .public) corrections")
        transcripts.insert(transcript, at: 0)
        if transcripts.count > Self.capacity {
            transcripts.removeLast(transcripts.count - Self.capacity)
        }
        save()
        // Analysis is scheduled only after the transcript is persisted, so
        // transcription latency is never affected by it.
        LearningScan.shared.scheduleQueue()
    }

    /// Replace a transcript in place — used when a summary lands on one.
    func update(_ transcript: Transcript) {
        guard let index = transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
        transcripts[index] = transcript
        save()
    }

    /// Applies a newly added correction to all existing transcripts.
    ///
    /// A correction is usually added because an error was noticed in an existing
    /// transcript, so restricting corrections to future output would address
    /// only half the problem.
    ///
    /// Only the new rule is applied, never the full set, which makes the
    /// operation idempotent with respect to previously applied corrections.
    /// `raw` is never modified, so the original recogniser output remains
    /// recoverable.
    @discardableResult
    func applyRetroactively(_ pair: CorrectionPair) -> Int {
        guard pair.enabled, !pair.hear.trimmed.isEmpty, !pair.write.trimmed.isEmpty else { return 0 }

        var changed = 0
        for index in transcripts.indices {
            var transcript = transcripts[index]
            let result = CorrectionEngine.apply(transcript.text, corrections: [pair])
            guard !result.applied.isEmpty else { continue }

            transcript.text = result.text
            transcript.corrections.append(contentsOf: result.applied)
            transcript.segments = transcript.segments.map { segment in
                var copy = segment
                copy.text = CorrectionEngine.apply(segment.text, corrections: [pair]).text
                return copy
            }
            transcripts[index] = transcript
            changed += 1
        }

        if changed > 0 {
            save()
            Log.app.info("retroactive correction \(pair.hear, privacy: .public): \(changed, privacy: .public) transcripts updated")
        }
        return changed
    }

    func markAnalysed(_ id: UUID, findings: Int) {
        guard let index = transcripts.firstIndex(where: { $0.id == id }) else { return }
        transcripts[index].analyzedAt = Date()
        transcripts[index].analysisFindings = findings
        save()
    }

    func resetAnalysis() {
        for index in transcripts.indices {
            transcripts[index].analyzedAt = nil
            transcripts[index].analysisFindings = 0
        }
        save()
    }

    var pendingAnalysis: [Transcript] { transcripts.filter { $0.analyzedAt == nil } }

    func delete(ids: Set<UUID>) {
        Log.app.info("history delete: \(ids.count, privacy: .public)")
        transcripts.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        Log.app.info("history cleared (\(self.transcripts.count, privacy: .public) removed)")
        transcripts.removeAll()
        save()
    }

    func search(_ query: String) -> [Transcript] {
        let q = query.trimmed
        guard !q.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || $0.raw.localizedCaseInsensitiveContains(q)
                || $0.corrections.contains { c in
                    c.write.localizedCaseInsensitiveContains(q) || c.hear.localizedCaseInsensitiveContains(q)
                }
        }
    }

    func copy(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Storage.historyURL) else { return }
        do {
            transcripts = try Storage.decoder.decode([Transcript].self, from: data)
        } catch {
            // Report rather than swallow: loading an empty list and then
            // persisting it would destroy the existing history.
            Log.app.error("history load failed, keeping file intact: \(error.localizedDescription, privacy: .public)")
            transcripts = []
        }
    }

    private func save() {
        do {
            let data = try Storage.encoder.encode(transcripts)
            try data.write(to: Storage.historyURL, options: .atomic)
        } catch {
            Log.app.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
