import AppKit
import Combine
import Foundation

/// Owns `dictionary.json` and is the single source of truth for both
/// mechanisms: the contextual strings supplied to the recogniser, and the
/// post-transcription correction pass.
@MainActor
final class DictionaryStore: ObservableObject {

    static let shared = DictionaryStore()

    @Published private(set) var terms: [VocabularyTerm] = []
    @Published private(set) var corrections: [CorrectionPair] = []
    @Published private(set) var lastExternalEdit: Date?
    @Published private(set) var loadError: String?
    /// What the last learned correction changed in existing transcripts.
    @Published var retroNote: String?

    /// Maximum number of terms supplied to the recogniser as context. Long
    /// context lists cause the model to drift and emit spurious text on
    /// near-silent audio, so this limit is intentionally conservative.
    static let biasLimit = 40

    private var watcher: FileWatcher?
    private var isWritingOurselves = false

    private init() {
        load()
        seedIfEmpty()
        watch()
    }

    var fileURL: URL { Storage.dictionaryURL }

    // MARK: - Bias list
    //
    // Ordering matters because the list is truncated. Explicit vocabulary comes
    // first, followed by correction targets: biasing the recogniser toward the
    // corrected spelling reduces the work left to the correction pass.

    var biasStrings: [String] {
        var seen = Set<String>()
        var out: [String] = []

        for term in terms where term.enabled {
            let text = term.text.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        for pair in corrections where pair.enabled {
            let text = pair.write.trimmed
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
        }
        return Array(out.prefix(Self.biasLimit))
    }

    /// Whether a correction already guarantees this spelling. Recogniser bias
    /// alone does not, so the interface distinguishes the two cases.
    func hasCorrection(targeting term: String) -> Bool {
        let target = term.trimmed.lowercased()
        guard !target.isEmpty else { return false }
        return corrections.contains { $0.enabled && $0.write.trimmed.lowercased() == target }
    }

    var termsWithoutCorrections: Int {
        terms.filter { $0.enabled && !hasCorrection(targeting: $0.text) }.count
    }

    var biasOverflow: Int {
        max(0, (terms.filter(\.enabled).count + corrections.filter(\.enabled).count) - Self.biasLimit)
    }

    // MARK: - Mutation

    func addTerm(_ text: String, note: String = "") {
        let clean = text.trimmed
        guard !clean.isEmpty else { return }
        terms.append(VocabularyTerm(text: clean, note: note.trimmed))
        save()
    }

    func update(_ term: VocabularyTerm) {
        guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[index] = term
        save()
    }

    func delete(termIDs: Set<UUID>) {
        terms.removeAll { termIDs.contains($0.id) }
        save()
    }

    func addCorrection(hear: String, write: String) {
        let h = hear.trimmed, w = write.trimmed
        guard !h.isEmpty, !w.isEmpty else { return }
        let pair = CorrectionPair(hear: h, write: w)
        corrections.append(pair)
        save()

        // Learning a word fixes the past too, not just the future.
        let updated = HistoryStore.shared.applyRetroactively(pair)
        retroNote = updated > 0
            ? "“\(h)” → “\(w)” — also fixed in \(updated) existing transcript\(updated == 1 ? "" : "s")."
            : "“\(h)” → “\(w)” added. It didn't appear in any existing transcript."
        recordHits([AppliedCorrection(hear: h, write: w, matched: h)])
    }

    func dismissRetroNote() { retroNote = nil }

    func update(_ pair: CorrectionPair) {
        guard let index = corrections.firstIndex(where: { $0.id == pair.id }) else { return }
        corrections[index] = pair
        save()
    }

    func delete(correctionIDs: Set<UUID>) {
        corrections.removeAll { correctionIDs.contains($0.id) }
        save()
    }

    /// Increments hit counts so the interface can show which entries are
    /// actually firing.
    func recordHits(_ applied: [AppliedCorrection]) {
        guard !applied.isEmpty else { return }
        var changed = false
        for hit in applied {
            if let index = corrections.firstIndex(where: { $0.hear.caseInsensitiveCompare(hit.hear) == .orderedSame }) {
                corrections[index].hitCount += 1
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Disk

    func load() {
        guard let data = try? Data(contentsOf: Storage.dictionaryURL) else {
            loadError = nil
            return
        }
        do {
            let file = try Storage.decoder.decode(DictionaryFile.self, from: data)
            terms = file.terms
            corrections = file.corrections
            loadError = nil
        } catch {
            // Never overwrite a file that failed to parse; it may be mid-edit.
            // Report the error and leave the file untouched.
            loadError = "dictionary.json couldn't be read: \(error.localizedDescription)"
            Log.app.error("dictionary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() {
        // A file that could not be parsed is never written over. It may be
        // mid-edit by hand, or damaged in a way the user can still repair --
        // and overwriting it with what little loaded turns a recoverable
        // problem into a permanent one.
        guard loadError == nil else {
            Log.app.error("dictionary save suppressed: the store did not load cleanly")
            return
        }
        let file = DictionaryFile(version: 1, terms: terms, corrections: corrections)
        do {
            let data = try Storage.encoder.encode(file)
            isWritingOurselves = true
            try Storage.writePrivately(data, to: Storage.dictionaryURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isWritingOurselves = false
            }
            loadError = nil
        } catch {
            loadError = "Couldn't save dictionary.json: \(error.localizedDescription)"
            Log.app.error("dictionary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Storage.dictionaryURL])
    }

    private func watch() {
        if !FileManager.default.fileExists(atPath: Storage.dictionaryURL.path) { save() }
        watcher = FileWatcher(url: Storage.dictionaryURL) { [weak self] in
            guard let self, !self.isWritingOurselves else { return }
            Log.app.info("dictionary.json changed on disk, reloading")
            self.load()
            self.lastExternalEdit = Date()
        }
    }

    /// Seed entries on first run, so the two entry types are self-explanatory.
    private func seedIfEmpty() {
        guard terms.isEmpty, corrections.isEmpty,
              !FileManager.default.fileExists(atPath: Storage.dictionaryURL.path) else { return }
        // Seed entries demonstrate the intended pairing: a vocabulary term for
        // recogniser bias, plus the correction that guarantees the spelling.
        terms = [
            VocabularyTerm(text: "Supabase"),
            VocabularyTerm(text: "Vercel"),
            VocabularyTerm(text: "Kubernetes"),
            VocabularyTerm(text: "PostgreSQL"),
            VocabularyTerm(text: "PowerShell")
        ]
        corrections = [
            CorrectionPair(hear: "super base", write: "Supabase"),
            CorrectionPair(hear: "versal", write: "Vercel"),
            CorrectionPair(hear: "cuber netties", write: "Kubernetes"),
            CorrectionPair(hear: "post gress", write: "PostgreSQL"),
            CorrectionPair(hear: "power shell", write: "PowerShell")
        ]
        save()
    }
}
