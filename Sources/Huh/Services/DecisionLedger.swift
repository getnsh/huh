import Combine
import Foundation

/// What was decided about a token the analysis pass surfaced.
enum LearningDecision: String, Codable {
    /// Filed as a person. `resolved` holds the canonical name.
    case person
    /// Added to the dictionary as vocabulary, spelled as heard.
    case term
    /// Added as a substitution rule. `resolved` holds the replacement.
    case correction
    /// Explicitly rejected. Never surfaced again.
    case ignored
}

struct LearningRecord: Codable, Identifiable, Hashable {
    /// Lower-cased token. The identity of a decision is the word it was about.
    var token: String
    var display: String
    var decision: LearningDecision
    var resolved: String = ""
    var date: Date = Date()

    var id: String { token }
}

/// A permanent record of every token the analysis pass has already asked about.
///
/// This exists because being asked the same question repeatedly is the fastest
/// way to make a review queue worthless. Dismissal used to be the only recorded
/// outcome, and it lived in user defaults as a bare list of strings — which
/// meant accepting a suggestion left no trace, and the next pass over the same
/// history proposed it again.
///
/// Every outcome is now recorded, including acceptance, and every producer of
/// candidates consults the ledger before surfacing anything. The ledger is the
/// authority on what has been seen; the dictionary and the people store are the
/// authorities on what was concluded.
@MainActor
final class DecisionLedger: ObservableObject {

    static let shared = DecisionLedger()

    @Published private(set) var records: [String: LearningRecord] = [:]

    /// Set when `decisions.json` exists but could not be parsed. While it is
    /// set, nothing is written. Without this the ledger answers "never seen"
    /// for every token after a single damaged byte, and the first write
    /// replaces a full history of answered questions with one entry -- so
    /// every suggestion the user has ever dismissed comes back, for good.
    @Published private(set) var loadError: String?

    private init() {
        load()
        migrateLegacyDismissals()
    }

    // MARK: - Query

    static func normalise(_ token: String) -> String {
        token.trimmed.lowercased()
    }

    func decision(for token: String) -> LearningRecord? {
        records[Self.normalise(token)]
    }

    /// The single question every candidate producer must ask.
    func isDecided(_ token: String) -> Bool {
        records[Self.normalise(token)] != nil
    }

    var ignoredCount: Int {
        records.values.filter { $0.decision == .ignored }.count
    }

    var count: Int { records.count }

    // MARK: - Record

    func record(_ token: String, decision: LearningDecision, resolved: String = "") {
        let key = Self.normalise(token)
        guard !key.isEmpty else { return }
        records[key] = LearningRecord(
            token: key,
            display: token.trimmed,
            decision: decision,
            resolved: resolved.trimmed
        )
        save()
        Log.app.info("decision: \(decision.rawValue, privacy: .public)")
    }

    /// Reverses a decision so the token can be proposed again. Used only by the
    /// explicit restore action.
    func forget(_ token: String) {
        records.removeValue(forKey: Self.normalise(token))
        save()
    }

    /// Restores every rejected token. Accepted ones stay decided: they became
    /// dictionary or people entries, and re-proposing them would be a bug.
    func restoreIgnored() {
        records = records.filter { $0.value.decision != .ignored }
        save()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Storage.decisionsURL) else {
            loadError = nil
            return
        }
        do {
            let list = try Storage.decoder.decode([LearningRecord].self, from: data)
            records = Dictionary(list.map { ($0.token, $0) }, uniquingKeysWith: { _, later in later })
            loadError = nil
        } catch {
            loadError = "decisions.json couldn't be read: \(error.localizedDescription)"
            Log.app.error("decision ledger load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        // A file that could not be parsed is never written over. It may be
        // mid-edit by hand, or damaged in a way the user can still repair --
        // and overwriting it with what little loaded turns a recoverable
        // problem into a permanent one.
        guard loadError == nil else {
            Log.app.error("decision ledger save suppressed: the store did not load cleanly")
            return
        }
        do {
            let list = records.values.sorted { $0.token < $1.token }
            try Storage.writePrivately(Storage.encoder.encode(list), to: Storage.decisionsURL)
        } catch {
            Log.app.error("decision ledger save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dismissals previously lived in user defaults. Carried across once, then
    /// the old key is removed so the two cannot disagree.
    private func migrateLegacyDismissals() {
        let key = "dismissedVocabulary"
        guard let legacy = UserDefaults.standard.stringArray(forKey: key), !legacy.isEmpty else { return }
        for token in legacy where records[Self.normalise(token)] == nil {
            records[Self.normalise(token)] = LearningRecord(
                token: Self.normalise(token),
                display: token,
                decision: .ignored
            )
        }
        UserDefaults.standard.removeObject(forKey: key)
        save()
        Log.app.info("migrated \(legacy.count, privacy: .public) dismissals into the decision ledger")
    }
}
