import SwiftUI

/// A stored name.
///
/// The row shows the spellings the recogniser is known to produce for this
/// person, because that is the part that does the work: the name alone only
/// biases recognition, while each alias is a guaranteed rewrite.
struct PersonRow: View {
    let person: Person

    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var store = PeopleStore.shared

    private var rowID: String { "person-\(person.id.uuidString)" }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { person.enabled },
                set: { var copy = person; copy.enabled = $0; store.update(copy) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(person.enabled ? Theme.live : Theme.textTertiary)

            Text(person.name)
                .font(Theme.medium(13.5))
                .foregroundStyle(person.enabled ? Theme.textPrimary : Theme.textTertiary)

            if !person.aliases.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(person.aliases.joined(separator: ", "))
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if !person.note.isEmpty {
                Text(person.note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if person.learned {
                Chip(text: "learned", tint: Theme.live)
                    .help("Found by reading a transcript, and confirmed by you.")
            }

            if person.aliases.isEmpty {
                Chip(text: "hint only", tint: Theme.warning)
                    .help("The recogniser is nudged toward this spelling, but nothing guarantees it. Add what it writes instead under “also heard as”.")
            }

            if ui.hovered == rowID {
                HStack(spacing: 2) {
                    Button { ui.openEditor(.editPerson(person)) } label: { Image(systemName: "pencil") }
                        .buttonStyle(GhostButtonStyle())
                    Button { store.delete(ids: [person.id]) } label: { Image(systemName: "trash") }
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

/// Names the reading pass found, awaiting confirmation.
///
/// Confirming one files it in the people store and records the decision, so it
/// is never proposed again. Rejecting one records that too — which is the whole
/// point: a queue that asks the same question after every recording is worse
/// than no queue.
struct PersonProposalStrip: View {
    @ObservedObject private var extractor = TranscriptExtractor.shared
    @ObservedObject private var scan = LearningScan.shared
    @ObservedObject private var intelligence = ModelAvailability.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.live)
                SectionLabel("Names found in your transcripts")
                Spacer(minLength: 0)

                if scan.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(scan.stage.isEmpty ? "Reading…" : scan.stage)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            if !intelligence.isReady {
                IntelligenceNotice(compact: true)
            } else if extractor.people.isEmpty {
                Text(scan.pending > 0
                     ? "\(scan.pending) transcript\(scan.pending == 1 ? "" : "s") still to read."
                     : "Nothing waiting. Names turn up here as transcripts are read, and each one is only ever asked about once.")
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(extractor.people) { proposal in
                            PersonProposalRow(proposal: proposal)
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
        .animation(Theme.spring, value: extractor.people)
    }
}

private struct PersonProposalRow: View {
    let proposal: TranscriptExtractor.PersonProposal

    @ObservedObject private var extractor = TranscriptExtractor.shared
    @ObservedObject private var ui = UIState.shared

    private var rowID: String { "personprop-\(proposal.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if proposal.isSpelledCorrectly {
                    Text(proposal.name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.live)
                } else {
                    Text(proposal.heard)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.danger)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(proposal.name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.live)
                }

                if let timecode = proposal.timecode {
                    Text(timecode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                Button("Edit…") {
                    ui.openEditor(.newPerson)
                    ui.draftName = proposal.name
                    ui.draftAliases = proposal.isSpelledCorrectly ? "" : proposal.heard
                    extractor.dismiss(proposal)
                }
                .buttonStyle(GhostButtonStyle())

                Button("Not a name") { extractor.dismiss(proposal) }
                    .buttonStyle(GhostButtonStyle())

                Button(proposal.isSpelledCorrectly ? "Remember" : "Add") { extractor.accept(proposal) }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.textPrimary))
            }

            Text("“\(proposal.context)”")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight(rowID, radius: Theme.radiusControl)
    }
}
