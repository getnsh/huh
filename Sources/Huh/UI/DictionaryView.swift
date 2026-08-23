import SwiftUI

struct DictionaryView: View {
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var store = DictionaryStore.shared
    @ObservedObject private var people = PeopleStore.shared

    private var filteredPeople: [Person] {
        let q = ui.dictionaryQuery.trimmed
        guard !q.isEmpty else { return people.people }
        return people.people.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.note.localizedCaseInsensitiveContains(q)
                || $0.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filteredTerms: [VocabularyTerm] {
        let q = ui.dictionaryQuery.trimmed
        guard !q.isEmpty else { return store.terms }
        return store.terms.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.note.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredCorrections: [CorrectionPair] {
        let q = ui.dictionaryQuery.trimmed
        guard !q.isEmpty else { return store.corrections }
        return store.corrections.filter {
            $0.hear.localizedCaseInsensitiveContains(q) || $0.write.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs

            if let error = store.loadError {
                banner(error, tint: Theme.danger, symbol: "exclamationmark.triangle.fill")
            }

            if let note = store.retroNote {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.live)
                    Text(note)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { store.dismissRetroNote() }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.live.opacity(0.08)))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(Theme.spring, value: store.retroNote)
            }

            switch ui.dictionaryTab {
            case .terms:       SuggestionStrip()
            case .corrections: CorrectionProposalStrip()
            case .people:      PersonProposalStrip()
            }

            content

            footer
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(UIState.DictionaryTab.allCases) { tab in
                let count: Int = {
                    switch tab {
                    case .terms:       return store.terms.count
                    case .corrections: return store.corrections.count
                    case .people:      return people.people.count
                    }
                }()
                Button {
                    withAnimation(Theme.spring) { ui.dictionaryTab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.title)
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .font(Theme.medium(12.5))
                    .foregroundStyle(ui.dictionaryTab == tab ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(ui.dictionaryTab == tab ? Theme.raised : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch ui.dictionaryTab {
        case .terms:
            if filteredTerms.isEmpty {
                EmptyStateView(
                    symbol: "character.book.closed",
                    title: "No words yet",
                    message: "Add names, jargon and product names. They're passed to the recogniser as a hint — but a hint is all they are. Anything it keeps getting wrong needs a correction too."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTerms) { term in TermRow(term: term) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        case .corrections:
            if filteredCorrections.isEmpty {
                EmptyStateView(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "No corrections yet",
                    message: "“When you hear X, write Y.” This runs after transcription and is the reliable half of the dictionary — hints are a nudge, this is a guarantee."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredCorrections) { pair in CorrectionRow(pair: pair) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        case .people:
            if filteredPeople.isEmpty {
                EmptyStateView(
                    symbol: "person.2",
                    title: "No names yet",
                    message: "Names live here rather than in the dictionary, because a name settles once and then shouldn't move. Each one biases the recogniser and rewrites the spellings it gets wrong — and once it's here you won't be asked about it again."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredPeople) { person in PersonRow(person: person) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

            Text((ui.dictionaryTab == .people ? Storage.peopleURL : Storage.dictionaryURL)
                .path
                .replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(Theme.mono)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Reveal") {
                if ui.dictionaryTab == .people { people.revealInFinder() } else { store.revealInFinder() }
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            if store.biasOverflow > 0 {
                Text("Only the first \(DictionaryStore.biasLimit) entries are sent to the recogniser as hints — \(store.biasOverflow) beyond that rely on corrections.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.warning)
            } else {
                Text("\(Rules.bias.count) hints sent to the recogniser · \(store.termsWithoutCorrections) word\(store.termsWithoutCorrections == 1 ? "" : "s") rely on hints alone")
                    .font(Theme.body(11))
                    .foregroundStyle(store.termsWithoutCorrections > 0 ? Theme.warning : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func banner(_ text: String, tint: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(Theme.body(12))
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(tint.opacity(0.10)))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Rows

private struct TermRow: View {
    let term: VocabularyTerm
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var store = DictionaryStore.shared

    private var rowID: String { "term-\(term.id.uuidString)" }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { term.enabled },
                set: { var t = term; t.enabled = $0; store.update(t) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text(term.text)
                .font(Theme.medium(13.5))
                .foregroundStyle(term.enabled ? Theme.textPrimary : Theme.textTertiary)

            if !term.note.isEmpty {
                Text(term.note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !store.hasCorrection(targeting: term.text) {
                Chip(text: "hint only", tint: Theme.warning)
                    .help("Words are only a hint to the recogniser. Add a correction to guarantee it.")
            }

            if ui.hovered == rowID {
                HStack(spacing: 2) {
                    if !store.hasCorrection(targeting: term.text) {
                        Button("Guarantee") { ui.openCorrection(forTerm: term.text) }
                            .buttonStyle(GhostButtonStyle(tint: Theme.live))
                            .help("Create a correction that always produces “\(term.text)”")
                    }
                    Button { ui.openEditor(.editTerm(term)) } label: { Image(systemName: "pencil") }
                        .buttonStyle(GhostButtonStyle())
                    Button { store.delete(termIDs: [term.id]) } label: { Image(systemName: "trash") }
                        .buttonStyle(GhostButtonStyle())
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .hoverHighlight(rowID, radius: Theme.radiusControl)
    }
}

private struct CorrectionRow: View {
    let pair: CorrectionPair
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var store = DictionaryStore.shared

    private var rowID: String { "corr-\(pair.id.uuidString)" }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { pair.enabled },
                set: { var p = pair; p.enabled = $0; store.update(p) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text(pair.hear)
                .font(Theme.mono)
                .foregroundStyle(pair.enabled ? Theme.textSecondary : Theme.textTertiary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            Text(pair.write)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(pair.enabled ? Theme.textPrimary : Theme.textTertiary)

            Spacer(minLength: 0)

            if pair.hitCount > 0 {
                Chip(text: "fired \(pair.hitCount)×", tint: Theme.live)
            }

            if ui.hovered == rowID {
                HStack(spacing: 2) {
                    Button { ui.openEditor(.editCorrection(pair)) } label: { Image(systemName: "pencil") }
                        .buttonStyle(GhostButtonStyle())
                    Button { store.delete(correctionIDs: [pair.id]) } label: { Image(systemName: "trash") }
                        .buttonStyle(GhostButtonStyle())
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .hoverHighlight(rowID, radius: Theme.radiusControl)
    }
}

// MARK: - Editor

struct EntryEditorSheet: View {
    @ObservedObject private var ui = UIState.shared

    private enum Mode { case term, correction, person }

    private var mode: Mode {
        switch ui.editor {
        case .newCorrection, .editCorrection: return .correction
        case .newPerson, .editPerson:         return .person
        default:                              return .term
        }
    }

    private var title: String {
        switch ui.editor {
        case .newTerm:          return "Add Word"
        case .editTerm:         return "Edit Word"
        case .newCorrection:    return "Add Correction"
        case .editCorrection:   return "Edit Correction"
        case .newPerson:        return "Add Person"
        case .editPerson:       return "Edit Person"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.textPrimary)

            if mode == .person {
                FormField(label: "Name", placeholder: "Katherine Ng", text: $ui.draftName)
                FormField(
                    label: "Also heard as",
                    placeholder: "Katharin, Catherine Eng",
                    text: $ui.draftAliases,
                    mono: true
                )
                FormField(label: "Note (optional)", placeholder: "who they are", text: $ui.draftNote)

                Text("Names are kept apart from the dictionary on purpose. Once a name is right it should stay that way, so nothing here is revised by a later pass and you won't be asked about it again. Each spelling under “also heard as” is rewritten to the name, and the name itself is passed to the recogniser as a hint.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if mode == .correction {
                FormField(label: "When you hear", placeholder: "store force", text: $ui.draftHear, mono: true)

                if !ui.draftContext.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Where it came up")
                        Text("“…\(ui.draftContext)…”")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.base))
                    }
                }
                FormField(label: "Write", placeholder: "StoreForce", text: $ui.draftWrite, mono: true)

                if !ui.draftHear.trimmed.isEmpty {
                    HStack(spacing: 8) {
                        if ModelAvailability.shared.isReady {
                            Button {
                                ui.suggestWriteForDraft()
                            } label: {
                                HStack(spacing: 5) {
                                    if ui.isSuggestingWrite {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "sparkles").font(.system(size: 9.5))
                                    }
                                    Text(ui.isSuggestingWrite ? "Thinking…" : "Ask the model")
                                }
                            }
                            .buttonStyle(GhostButtonStyle(tint: Theme.live))
                            .disabled(ui.isSuggestingWrite)
                        }

                        if ui.suggestionDeclined {
                            Text("The model wasn't confident enough to guess. Type it yourself.")
                                .font(Theme.body(11))
                                .foregroundStyle(Theme.textTertiary)
                        } else if !ModelAvailability.shared.isReady {
                            Text("Suggestions need Apple Intelligence. Type the replacement yourself.")
                                .font(Theme.body(11))
                                .foregroundStyle(Theme.textTertiary)
                        }

                        Spacer(minLength: 0)
                    }
                }

                if !ui.draftHear.trimmed.isEmpty {
                    matchExplanation
                }

                ForEach(ui.editorWarnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: warning.severity == .danger
                              ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.system(size: 11))
                        Text(warning.message)
                            .font(Theme.body(12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(warning.severity == .danger ? Theme.danger : Theme.textSecondary)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusControl)
                            .fill((warning.severity == .danger ? Theme.danger : Theme.textSecondary).opacity(0.10))
                    )
                }
            } else {
                FormField(label: "Word or phrase", placeholder: "StoreForce", text: $ui.draftText)
                FormField(label: "Note (optional)", placeholder: "what it is", text: $ui.draftNote)

                Text("Words are passed to the recogniser before it transcribes, so it leans toward producing them. Measured on clean audio, this changed nothing at all — treat it as a nudge and add a correction for anything that actually matters.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { ui.showingEditor = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { ui.commitEditor() }
                    .buttonStyle(PrimaryButtonStyle(enabled: ui.editorCanSave))
                    .disabled(!ui.editorCanSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    /// Shows the literal variants the pattern will match, so separator
    /// tolerance is visible rather than implied.
    private var matchExplanation: some View {
        let words = ui.draftHear.trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let variants: [String] = words.count > 1
            ? [words.joined(separator: " "), words.joined(), words.joined(separator: "-")]
            : [String(words.first ?? "")]

        return VStack(alignment: .leading, spacing: 6) {
            Text("Also catches")
                .font(Theme.medium(11))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            HStack(spacing: 6) {
                ForEach(Array(Set(variants)).sorted(), id: \.self) { variant in
                    Text(variant)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
                }
                Spacer(minLength: 0)
            }
            Text("Case-insensitive, whole words only — never inside a longer word.")
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Learned suggestions

/// Frequently spoken tokens absent from the system dictionary.
///
/// This is a precise operational definition of domain vocabulary. The system
/// spell checker and named-entity recogniser do the detection, so no word list
/// is bundled and no model is required for this step.
struct SuggestionStrip: View {
    @ObservedObject private var suggester = VocabularySuggester.shared
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        if !suggester.candidates.isEmpty || suggester.suppressedCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.live)
                        SectionLabel("Heard often, not in any dictionary")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text("Click one: add it as a word if the spelling is right, or fix it if it's a mis-hearing.")
                            .font(Theme.body(11.5))
                            .foregroundStyle(Theme.textTertiary)
                        if suggester.suppressedCount > 0 {
                            Button("Show \(suggester.suppressedCount) dismissed") {
                                suggester.resetDismissed()
                            }
                            .buttonStyle(GhostButtonStyle(tint: Theme.live))
                        }
                        Spacer(minLength: 0)
                    }
                }

                ScrollView {
                    FlowRow(spacing: 6) {
                        ForEach(suggester.candidates) { candidate in
                            SuggestionChip(candidate: candidate)
                        }
                    }
                }
                .frame(maxHeight: 96)
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.borderSoft, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .offset(y: -8)))
            .animation(Theme.spring, value: suggester.candidates)
        }
    }
}

private struct SuggestionChip: View {
    let candidate: VocabularySuggester.Candidate
    @ObservedObject private var suggester = VocabularySuggester.shared
    @ObservedObject private var ui = UIState.shared

    private var hoverID: String { "sug-\(candidate.id)" }

    var body: some View {
        // A menu rather than icon buttons. The two available actions are
        // opposites and neither is a conventional icon, so each is labelled in
        // full.
        Menu {
            Button("Add “\(candidate.word)” as a word") {
                suggester.accept(candidate)
            }
            Button("It's someone's name — remember it") {
                suggester.acceptAsPerson(candidate)
            }
            Button("It's a mis-hearing — fix it…") {
                // Does not dismiss the candidate: cancelling the editor must
                // leave it in place. Saving removes it implicitly, since the
                // trigger then counts as known.
                ui.fixHeardWord(candidate.word)
            }
            Divider()
            Button("Never suggest this") {
                suggester.dismiss(candidate)
            }
        } label: {
            HStack(spacing: 6) {
                if candidate.isName {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.live)
                }
                Text(candidate.word)
                    .font(Theme.medium(12.5))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(candidate.count)×")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(ui.hovered == hoverID ? Theme.hover : Theme.base))
            .overlay(Capsule().strokeBorder(ui.hovered == hoverID ? Theme.border : Theme.borderSoft, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in
            withAnimation(Theme.quick) {
                if inside { ui.hovered = hoverID } else if ui.hovered == hoverID { ui.hovered = nil }
            }
        }
    }
}

/// Wrapping row layout. SwiftUI provides no built-in flow layout, and a plain
/// `HStack` overflows once entries exceed the available width.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Model-proposed corrections

/// Corrections proposed by the on-device model.
///
/// Detection identifies which tokens are wrong; resolving what they should be
/// requires world knowledge, which is what the model supplies. Proposals are
/// validated before display and are never applied without explicit
/// confirmation.
struct CorrectionProposalStrip: View {
    @ObservedObject private var suggester = CorrectionSuggester.shared
    @ObservedObject private var vocabulary = VocabularySuggester.shared
    @ObservedObject private var intelligence = ModelAvailability.shared
    @ObservedObject private var scan = LearningScan.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.live)
                SectionLabel("Suggested fixes")
                Spacer(minLength: 0)

                if scan.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(scan.stage.isEmpty ? "Reading on-device…" : scan.stage)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                } else {
                    Button(scan.pending > 0 ? "Read \(scan.pending) unread" : "Read again") {
                        if intelligence.isReady {
                            scan.runManually()
                        } else {
                            ui.showingIntelligenceNotice = true
                        }
                    }
                    .buttonStyle(GhostButtonStyle(tint: Theme.live))
                    .disabled(history.transcripts.isEmpty)
                }
            }

            if ui.showingIntelligenceNotice && !intelligence.isReady {
                IntelligenceNotice(compact: true)
            } else if let failure = suggester.failure {
                Text(failure)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.danger)
            } else if suggester.proposals.isEmpty {
                Text(hint)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(suggester.proposals) { proposal in
                            ProposalRow(proposal: proposal)
                        }
                    }
                }
                .frame(maxHeight: 210)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.borderSoft, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(Theme.spring, value: suggester.proposals)
    }

    private var hint: String {
        if history.transcripts.isEmpty {
            return "Nothing to work with yet — transcribe something first."
        }
        if scan.pending > 0 {
            return "\(scan.pending) transcript\(scan.pending == 1 ? "" : "s") still to read. Each one is read in passages, so the model sees the sentences around a word rather than the word alone."
        }
        if suggester.lastRunFoundNothing || vocabulary.candidates.isEmpty {
            return "Every transcript has been read and nothing in them looked like a mis-hearing. That's a real answer, not a failure."
        }
        return "\(vocabulary.candidates.count) unrecognised word\(vocabulary.candidates.count == 1 ? "" : "s") are still under review. Anything the model recognised as a garbled name or product appears here."
    }
}

private struct ProposalRow: View {
    let proposal: CorrectionSuggester.Proposal

    @ObservedObject private var suggester = CorrectionSuggester.shared
    @ObservedObject private var ui = UIState.shared

    private var rowID: String { "prop-\(proposal.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(proposal.heard)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.danger)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(proposal.write)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.live)

                Spacer(minLength: 8)

                if proposal.isRisky {
                    Chip(text: "risky", tint: Theme.danger)
                }

                Button("It's a name") { suggester.acceptAsPerson(proposal) }
                    .buttonStyle(GhostButtonStyle(tint: Theme.live))
                    .help("File “\(proposal.write)” under People instead, where it won't be revised or asked about again.")
                Button("Edit…") { suggester.edit(proposal) }
                    .buttonStyle(GhostButtonStyle())
                Button("Dismiss") { suggester.dismiss(proposal) }
                    .buttonStyle(GhostButtonStyle())
                Button("Add") { suggester.accept(proposal) }
                    .buttonStyle(SecondaryButtonStyle(tint: proposal.isRisky ? Theme.warning : Theme.textPrimary))
            }

            Text("“…\(proposal.context)…”")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            ForEach(proposal.warnings.filter { $0.severity == .danger }) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(warning.message)
                        .font(Theme.body(11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight(rowID, radius: Theme.radiusControl)
    }
}
