import Combine
import Foundation

/// Transient view state for the main window.
///
/// View state is centralised in an observable object rather than distributed
/// across views. This keeps the interface's entire state inspectable in one
/// place, and avoids a dependency on the SwiftUI macro plugin, which is not
/// present in Command Line Tools installations.
@MainActor
final class UIState: ObservableObject {

    static let shared = UIState()

    enum Section: String, CaseIterable, Identifiable {
        case transcripts, dictionary
        var id: String { rawValue }
        var title: String { self == .transcripts ? "Transcripts" : "Dictionary" }
        var symbol: String { self == .transcripts ? "text.alignleft" : "character.book.closed" }
    }

    enum DictionaryTab: String, CaseIterable, Identifiable {
        case terms, corrections, people
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terms:       return "Words"
            case .corrections: return "Corrections"
            case .people:      return "People"
            }
        }
    }

    enum Editor: Equatable {
        case newTerm
        case editTerm(VocabularyTerm)
        case newCorrection
        case editCorrection(CorrectionPair)
        case newPerson
        case editPerson(Person)
    }

    @Published var section: Section = .transcripts

    // Transcripts
    @Published var transcriptQuery = ""
    /// The transcript open in the detail view, if any.
    @Published var openTranscript: UUID?

    // Dictionary
    @Published var dictionaryTab: DictionaryTab = .terms
    @Published var dictionaryQuery = ""

    // Editor sheet
    @Published var showingEditor = false
    @Published var editor: Editor = .newTerm
    @Published var draftText = ""
    @Published var draftNote = ""
    @Published var draftHear = ""
    @Published var draftWrite = ""
    /// The sentence the token appeared in, shown as disambiguating context.
    @Published private(set) var draftContext = ""
    @Published private(set) var isSuggestingWrite = false
    @Published private(set) var suggestionDeclined = false

    /// Draft fields for the people editor. A name and the spellings the
    /// recogniser produces for it.
    @Published var draftName = ""
    @Published var draftAliases = ""

    @Published var confirmingClear = false
    /// Reveals the on-device model requirement after a model-backed control is
    /// used while the model is unavailable.
    @Published var showingIntelligenceNotice = false
    @Published var isDropTargeted = false

    /// Identifier of the hovered row, held centrally rather than per row.
    @Published var hovered: String?

    var editorWarnings: [CorrectionSafety.Warning] {
        switch editor {
        case .newCorrection, .editCorrection:
            return CorrectionSafety.check(hear: draftHear, write: draftWrite)
        default:
            return []
        }
    }

    var editorCanSave: Bool {
        switch editor {
        case .newTerm, .editTerm:
            return !draftText.trimmed.isEmpty
        case .newCorrection, .editCorrection:
            return !draftHear.trimmed.isEmpty && !draftWrite.trimmed.isEmpty
        case .newPerson, .editPerson:
            return !draftName.trimmed.isEmpty
        }
    }

    /// Aliases are entered as one comma-separated field rather than a repeating
    /// list control: a name usually has one or two mis-hearings, and a list
    /// editor for two items costs more to use than it saves.
    static func splitAliases(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    func openEditor(_ editor: Editor) {
        self.editor = editor
        switch editor {
        case .newTerm:
            draftText = ""; draftNote = ""
        case .editTerm(let term):
            draftText = term.text; draftNote = term.note
        case .newCorrection:
            draftHear = ""; draftWrite = ""
        case .editCorrection(let pair):
            draftHear = pair.hear; draftWrite = pair.write
        case .newPerson:
            draftName = ""; draftAliases = ""; draftNote = ""
        case .editPerson(let person):
            draftName = person.name
            draftAliases = person.aliases.joined(separator: ", ")
            draftNote = person.note
        }
        draftContext = ""
        suggestionDeclined = false
        showingEditor = true
    }

    /// Promotes a vocabulary term into a correction rule. Terms are advisory
    /// bias only; a correction is the deterministic path. The replacement is
    /// prefilled, leaving only the trigger to supply.
    func openCorrection(forTerm term: String) {
        editor = .newCorrection
        draftHear = ""
        draftWrite = term
        showingEditor = true
    }

    /// Opens the correction editor with both fields populated, for reviewing a
    /// model-proposed rule before saving.
    func openCorrection(prefilledHear hear: String, write: String = "") {
        editor = .newCorrection
        draftHear = hear
        draftWrite = write
        draftContext = ""
        suggestionDeclined = false
        showingEditor = true
    }

    /// Populates the replacement field using the on-device model. A declined
    /// request is a valid outcome rather than an error, and is reported as
    /// such.
    func suggestWriteForDraft() {
        let heard = draftHear.trimmed
        guard !heard.isEmpty, !isSuggestingWrite else { return }
        isSuggestingWrite = true
        suggestionDeclined = false
        Task {
            let answer = await CorrectionSuggester.shared.suggest(for: heard)
            if let answer, !answer.isEmpty {
                draftWrite = answer
            } else {
                suggestionDeclined = true
            }
            isSuggestingWrite = false
        }
    }

    /// Opens the correction editor for a token and requests a suggested
    /// replacement in the same action.
    func fixHeardWord(_ heard: String) {
        openCorrection(prefilledHear: heard)
        draftContext = CorrectionSuggester.context(for: heard)
        if CorrectionSuggester.shared.isAvailable {
            suggestWriteForDraft()
        }
    }

    func commitEditor() {
        let store = DictionaryStore.shared
        switch editor {
        case .newTerm:
            store.addTerm(draftText, note: draftNote)
        case .editTerm(var term):
            term.text = draftText.trimmed
            term.note = draftNote.trimmed
            store.update(term)
        case .newCorrection:
            store.addCorrection(hear: draftHear, write: draftWrite)
        case .editCorrection(var pair):
            pair.hear = draftHear.trimmed
            pair.write = draftWrite.trimmed
            store.update(pair)
        case .newPerson:
            let people = PeopleStore.shared
            if let person = people.add(name: draftName, note: draftNote) {
                for alias in Self.splitAliases(draftAliases) {
                    people.addAlias(alias, forName: person.name)
                }
            }
        case .editPerson(var person):
            person.name = draftName.trimmed
            person.aliases = Self.splitAliases(draftAliases)
            person.note = draftNote.trimmed
            PeopleStore.shared.update(person)
        }
        showingEditor = false
        VocabularySuggester.shared.refresh()
    }
}
