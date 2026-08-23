import AppKit
import Combine
import Foundation

/// Owns `people.json`.
///
/// Deliberately not part of `DictionaryStore`. Merging the two would mean a
/// name shares a lifecycle with vocabulary hints and hand-written substitutions,
/// and the whole point of this store is that a name settles once and then stops
/// moving: it is not re-proposed, not re-derived, and not silently altered by a
/// later pass.
///
/// The store contributes to both dictation mechanisms — canonical names bias the
/// recogniser, and each alias becomes a rewrite rule — but it owns neither, so
/// the dictionary file stays exactly what the user put in it.
@MainActor
final class PeopleStore: ObservableObject {

    static let shared = PeopleStore()

    @Published private(set) var people: [Person] = []
    @Published private(set) var loadError: String?
    @Published private(set) var lastExternalEdit: Date?

    /// Names supplied to the recogniser as bias. Capped for the same reason the
    /// dictionary's list is: long context lists make the recogniser drift.
    static let biasLimit = 24

    private var watcher: FileWatcher?
    private var isWritingOurselves = false

    private init() {
        load()
        watch()
    }

    var fileURL: URL { Storage.peopleURL }

    // MARK: - Contributions to dictation

    var biasStrings: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for person in people where person.enabled {
            let name = person.name.trimmed
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return Array(out.prefix(Self.biasLimit))
    }

    /// Aliases expressed as substitution rules, so the existing correction
    /// engine applies them without needing to know about people.
    ///
    /// Synthesised rather than stored as pairs: the alias list is the source of
    /// truth, and deriving the rules keeps the two from diverging.
    var correctionRules: [CorrectionPair] {
        var out: [CorrectionPair] = []
        for person in people where person.enabled {
            let name = person.name.trimmed
            guard !name.isEmpty else { continue }
            for alias in person.aliases {
                let heard = alias.trimmed
                guard !heard.isEmpty,
                      heard.compare(name, options: .caseInsensitive) != .orderedSame else { continue }
                out.append(CorrectionPair(hear: heard, write: name))
            }
        }
        return out
    }

    // MARK: - Lookup

    func person(named name: String) -> Person? {
        people.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// True when the token is a known name or a known mis-hearing of one. The
    /// analysis pass consults this before proposing anything.
    func knows(_ token: String) -> Bool {
        people.contains { $0.matches(token) }
    }

    var names: [String] { people.filter(\.enabled).map(\.name) }

    // MARK: - Mutation

    @discardableResult
    func add(name: String, alias: String? = nil, note: String = "", learned: Bool = false) -> Person? {
        let clean = name.trimmed
        guard !clean.isEmpty else { return nil }

        if var existing = person(named: clean) {
            if let alias = alias?.trimmed, !alias.isEmpty { addAlias(alias, to: &existing) }
            return existing
        }

        var person = Person(name: clean, note: note.trimmed, learned: learned)
        if let alias = alias?.trimmed, !alias.isEmpty,
           alias.compare(clean, options: .caseInsensitive) != .orderedSame {
            person.aliases = [alias]
        }
        people.append(person)
        save()
        applyAliasesRetroactively(person)
        return person
    }

    /// Records that the recogniser writes `alias` when it means `name`.
    @discardableResult
    func addAlias(_ alias: String, forName name: String) -> Bool {
        let clean = alias.trimmed
        guard !clean.isEmpty else { return false }
        guard var existing = person(named: name) else {
            return add(name: name, alias: clean, learned: true) != nil
        }
        addAlias(clean, to: &existing)
        return true
    }

    private func addAlias(_ alias: String, to person: inout Person) {
        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
        let clean = alias.trimmed
        guard !clean.isEmpty,
              clean.compare(person.name, options: .caseInsensitive) != .orderedSame,
              !person.aliases.contains(where: { $0.compare(clean, options: .caseInsensitive) == .orderedSame })
        else { return }
        people[index].aliases.append(clean)
        person = people[index]
        save()
        applyAliasesRetroactively(people[index], only: clean)
    }

    func update(_ person: Person) {
        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[index] = person
        save()
    }

    func delete(ids: Set<UUID>) {
        people.removeAll { ids.contains($0.id) }
        save()
    }

    /// Fixing a name should fix the transcripts it was already wrong in.
    private func applyAliasesRetroactively(_ person: Person, only alias: String? = nil) {
        let aliases = alias.map { [$0] } ?? person.aliases
        var total = 0
        for value in aliases {
            let pair = CorrectionPair(hear: value, write: person.name)
            total += HistoryStore.shared.applyRetroactively(pair)
        }
        if total > 0 {
            Log.app.info("person aliases applied to \(total, privacy: .public) transcripts")
        }
    }

    // MARK: - Disk

    func load() {
        guard let data = try? Data(contentsOf: Storage.peopleURL) else {
            loadError = nil
            return
        }
        do {
            people = try Storage.decoder.decode(PeopleFile.self, from: data).people
            loadError = nil
        } catch {
            loadError = "people.json couldn't be read: \(error.localizedDescription)"
            Log.app.error("people load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() {
        do {
            let data = try Storage.encoder.encode(PeopleFile(version: 1, people: people))
            isWritingOurselves = true
            try data.write(to: Storage.peopleURL, options: .atomic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isWritingOurselves = false
            }
            loadError = nil
        } catch {
            loadError = "Couldn't save people.json: \(error.localizedDescription)"
            Log.app.error("people save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Storage.peopleURL])
    }

    private func watch() {
        if !FileManager.default.fileExists(atPath: Storage.peopleURL.path) { save() }
        watcher = FileWatcher(url: Storage.peopleURL) { [weak self] in
            guard let self, !self.isWritingOurselves else { return }
            Log.app.info("people.json changed on disk, reloading")
            self.load()
            self.lastExternalEdit = Date()
        }
    }
}
