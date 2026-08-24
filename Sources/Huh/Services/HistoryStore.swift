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
    /// Set when history could not be read. While this holds a value the store
    /// refuses to write, so a file it failed to parse is never overwritten.
    @Published private(set) var loadError: String?

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
            Log.app.info("retroactive correction applied to \(changed, privacy: .public) transcripts")
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
        discardCorruptCopy()
    }

    func clear() {
        Log.app.info("history cleared (\(self.transcripts.count, privacy: .public) removed)")
        transcripts.removeAll()
        save()
        discardCorruptCopy()
    }

    /// Removes the salvage copy left behind by a failed parse.
    ///
    /// `history.corrupt.json` is a complete copy of the transcripts. Leaving
    /// it in place after the user has deleted them means the deletion did not
    /// happen: the text is still on disk, in the same directory, under a name
    /// nobody thinks to look for.
    private func discardCorruptCopy() {
        let copy = Storage.corruptHistoryURL
        guard FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.removeItem(at: copy)
        Log.app.info("removed the salvaged copy of the transcript history")
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
            loadError = nil
        } catch {
            // The in-memory list is deliberately left alone. Emptying it here
            // and then saving -- which the next dictation would do within
            // seconds -- is what would actually destroy the history this is
            // trying to protect.
            let backup = Storage.corruptHistoryURL
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Storage.historyURL, to: backup)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

            loadError = "Transcript history couldn't be read. The file has been left untouched and copied to history.corrupt.json; nothing new will be saved until it is fixed or removed."
            Log.app.error("history load failed, refusing to write: \(error.localizedDescription)")
        }
    }

    private func save() {
        // Never write over a file that could not be parsed.
        guard loadError == nil else {
            Log.app.error("history save suppressed: the store did not load cleanly")
            return
        }
        do {
            let data = try Storage.encoder.encode(transcripts)
            try Storage.writePrivately(data, to: Storage.historyURL)
        } catch {
            Log.app.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
