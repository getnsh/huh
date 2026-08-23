import SwiftUI

struct TranscriptsView: View {
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var files = FileTranscriptionService.shared
    @ObservedObject private var index = SearchIndex.shared

    private var isSearching: Bool { !ui.transcriptQuery.trimmed.isEmpty }

    private var openTranscript: Transcript? {
        guard let id = ui.openTranscript else { return nil }
        return history.transcripts.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let transcript = openTranscript {
                TranscriptDetail(transcript: transcript)
                    .transition(.opacity.combined(with: .offset(x: 14)))
            } else {
                browse
                    .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
        .animation(Theme.spring, value: ui.openTranscript)
    }

    // MARK: - Browse

    private var browse: some View {
        VStack(spacing: 0) {
            banners

            if history.transcripts.isEmpty {
                EmptyStateView(
                    symbol: "waveform",
                    title: "No transcripts yet",
                    message: "Hold your push-to-talk key anywhere, press Start below, or drop a meeting recording onto this window."
                )
            } else if isSearching {
                searchResults
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if files.job != nil || files.completedOriginal != nil || files.failure != nil {
            VStack(spacing: 8) {
                if let job = files.job { JobCard(job: job) }
                if let original = files.completedOriginal { TrashPrompt(url: original) }
                if let failure = files.failure { FailureBanner(message: failure) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.spring, value: files.job)
            .animation(Theme.spring, value: files.completedOriginal)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(history.transcripts) { transcript in
                    TranscriptCard(transcript: transcript)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = index.search(ui.transcriptQuery)
        if results.isEmpty {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "Nothing across \(history.transcripts.count) transcript\(history.transcripts.count == 1 ? "" : "s") matches “\(ui.transcriptQuery)”."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    HStack {
                        Text("\(results.count) transcript\(results.count == 1 ? "" : "s")")
                            .font(Theme.body(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)

                    ForEach(results) { hit in SearchResultRow(hit: hit) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - List card
//
// Rows identify rather than preview. An imported transcript leads with its name
// and shape; its text is rendered in the detail view, where it can be scrolled
// lazily. Rendering a substantial excerpt in a list row provides little value
// and costs layout time proportional to transcript length.

private struct TranscriptCard: View {
    let transcript: Transcript

    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var history = HistoryStore.shared

    private var rowID: String { "t-\(transcript.id.uuidString)" }
    private var isFile: Bool { transcript.source == .file }

    var body: some View {
        Button {
            ui.openTranscript = transcript.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isFile ? "waveform" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isFile ? Theme.live.opacity(0.8) : Theme.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isFile ? transcript.sourceName : transcript.text)
                        .font(isFile ? Theme.medium(13) : Theme.body(13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isFile ? 1 : 2)
                        .truncationMode(isFile ? .middle : .tail)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 7) {
                        Text(Self.relative.localizedString(for: transcript.date, relativeTo: Date()))
                        dot
                        if isFile {
                            Text(Self.clock(transcript.duration))
                            dot
                        }
                        Text("\(transcript.wordCount) words")
                        if !transcript.segments.isEmpty {
                            dot
                            Text("\(transcript.segments.count) lines")
                        }
                        LearningBadge(transcript: transcript)
                        if !transcript.summary.isEmpty {
                            Chip(text: "summarised", tint: Theme.live)
                        }
                        if transcript.wasCorrected {
                            Chip(text: "\(transcript.corrections.count) fixed", tint: Theme.textSecondary)
                        }
                    }
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                if ui.hovered == rowID {
                    TranscriptActions(transcript: transcript)
                        .transition(.opacity)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(ui.hovered == rowID ? 1 : 0.45))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(rowID)
    }

    private var dot: some View {
        Text("·").foregroundStyle(Theme.textTertiary.opacity(0.6))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Detail

private struct TranscriptDetail: View {
    let transcript: Transcript

    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var playback = PlaybackController.shared
    @ObservedObject private var summaries = SummaryService.shared
    @ObservedObject private var intelligence = ModelAvailability.shared

    private var playable: Bool { PlaybackController.isAvailable(for: transcript) }
    private var isSummarising: Bool { summaries.runningFor == transcript.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.borderSoft)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if ui.showingIntelligenceNotice && !intelligence.isReady {
                        IntelligenceNotice()
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }

                    if isSummarising || !transcript.summary.isEmpty {
                        SummaryCard(transcript: transcript, running: isSummarising)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }

                    if let failure = summaries.failure, isSummarisingContext {
                        FailureBanner(message: failure, onDismiss: { summaries.dismissFailure() })
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    if transcript.segments.isEmpty {
                        Text(transcript.text)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        // Lazily constructed, so only visible rows are built
                        // regardless of transcript length.
                        ForEach(transcript.segments) { segment in
                            SegmentRow(
                                segment: segment,
                                transcript: transcript,
                                playable: playable,
                                isActive: playback.activeSegmentID == segment.id
                            )
                        }
                        .padding(.horizontal, 10)

                        if transcript.wasCorrected {
                            CorrectionAudit(transcript: transcript)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private var isSummarisingContext: Bool {
        summaries.failure != nil && summaries.runningFor == nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                ui.openTranscript = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.source == .file ? transcript.sourceName : "Dictation")
                    .font(Theme.medium(13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    if transcript.duration > 0 {
                        Text(TranscriptCard.clock(transcript.duration))
                    }
                    Text("\(transcript.wordCount) words")
                    if transcript.cleanupRemoved > 0 {
                        Text("−\(transcript.cleanupRemoved) fillers")
                    }
                    if !playable, transcript.source == .file {
                        Text("· original not available")
                    }
                }
                .font(Theme.body(11))
                .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            LearningBadge(transcript: transcript)

            if playback.transcriptID == transcript.id {
                Button {
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.live))
                Button("Stop") { playback.stop() }
                    .buttonStyle(GhostButtonStyle())
            }

            summariseButton
            TranscriptActions(transcript: transcript)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var summariseButton: some View {
        if isSummarising {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(summaries.stage)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            // The control stays enabled regardless of model availability.
            // Pressing it either summarises or explains what is missing; a
            // disabled button communicates neither.
            Button(transcript.summary.isEmpty ? "Summarise" : "Redo Summary") {
                if intelligence.isReady {
                    summaries.summarise(transcript)
                } else {
                    ui.showingIntelligenceNotice = true
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// A single timeline row. Kept minimal: this view is instantiated once per
/// segment.
private struct SegmentRow: View {
    let segment: TranscriptSegment
    let transcript: Transcript
    let playable: Bool
    let isActive: Bool

    @ObservedObject private var playback = PlaybackController.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                playback.play(transcript, from: segment.start)
            } label: {
                Text(segment.timecode)
                    .font(Theme.mono)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.live : (playable ? Theme.textSecondary : Theme.textTertiary.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .disabled(!playable)

            Text(segment.text)
                .font(Theme.body(13))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.live.opacity(0.10) : .clear)
        )
    }
}

// MARK: - Summary

private struct SummaryCard: View {
    let transcript: Transcript
    let running: Bool

    @ObservedObject private var summaries = SummaryService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.live)
                SectionLabel("Summary")
                Spacer(minLength: 0)
                if running {
                    Text("\(Int(summaries.progress * 100))%")
                        .font(Theme.mono).monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .contentTransition(.numericText())
                } else if !transcript.summary.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.summary, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }

            if running {
                VStack(alignment: .leading, spacing: 7) {
                    Text(summaries.stage)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textTertiary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule().fill(Theme.live)
                                .frame(width: max(3, geo.size.width * summaries.progress))
                        }
                    }
                    .frame(height: 3)
                    .animation(Theme.quick, value: summaries.progress)
                    Text("Running entirely on this Mac — Apple's on-device model, nothing sent anywhere.")
                        .font(Theme.body(10.5))
                        .foregroundStyle(Theme.textTertiary.opacity(0.8))
                }
            } else {
                MarkdownBlock(text: transcript.summary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.live.opacity(0.22), lineWidth: 1))
    }
}

/// Renders the model's Markdown output. SwiftUI's inline parser handles
/// emphasis but not headings or lists, which are handled here.
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    SectionLabel(line.drop(while: { $0 == "#" || $0 == " " }).description)
                        .padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").foregroundStyle(Theme.textTertiary)
                        inline(String(line.dropFirst(2)))
                    }
                } else {
                    inline(line)
                }
            }
        }
    }

    private func inline(_ string: String) -> some View {
        Text((try? AttributedString(markdown: string)) ?? AttributedString(string))
            .font(Theme.body(12.5))
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Shared

private struct TranscriptActions: View {
    let transcript: Transcript
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        HStack(spacing: 2) {
            Button {
                TranscriptExporter.copy(transcript, as: transcript.segments.isEmpty ? .plain : .timestamped)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(GhostButtonStyle())
            .help(transcript.segments.isEmpty ? "Copy" : "Copy with timestamps")

            Menu {
                Button("Copy Plain Text") { TranscriptExporter.copy(transcript, as: .plain) }
                if !transcript.segments.isEmpty {
                    Button("Copy with Timestamps") { TranscriptExporter.copy(transcript, as: .timestamped) }
                }
                Button("Copy as Rich Text") { TranscriptExporter.copyRich(transcript) }
                Divider()
                Button("Send to Google Docs…") { TranscriptExporter.sendToGoogleDocs(transcript) }
                Divider()
                Menu("Export as") {
                    ForEach(TranscriptExporter.Format.allCases) { format in
                        if format == .plain || format == .markdown || !transcript.segments.isEmpty {
                            Button(format.title) { TranscriptExporter.save(transcript, as: format) }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)

            Button {
                if ui.openTranscript == transcript.id { ui.openTranscript = nil }
                history.delete(ids: [transcript.id])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

private struct CorrectionAudit: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Dictionary changes")
            ForEach(transcript.corrections) { correction in
                HStack(spacing: 7) {
                    Text(correction.matched)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.danger.opacity(0.1)))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(correction.write)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.live)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.live.opacity(0.1)))
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchIndex.Hit

    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var playback = PlaybackController.shared

    private var rowID: String { "s-\(hit.transcript.id.uuidString)" }
    private var playable: Bool { PlaybackController.isAvailable(for: hit.transcript) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: hit.transcript.source == .file ? "waveform" : "mic.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Button {
                    ui.transcriptQuery = ""
                    ui.openTranscript = hit.transcript.id
                } label: {
                    Text(hit.transcript.source == .file ? hit.transcript.sourceName : "Dictation")
                        .font(Theme.medium(12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Text(Self.formatter.string(from: hit.transcript.date))
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textTertiary)
                TranscriptActions(transcript: hit.transcript)
            }

            ForEach(hit.snippets) { snippet in
                HStack(alignment: .top, spacing: 9) {
                    if let timecode = snippet.timecode, let start = snippet.start {
                        Button {
                            playback.play(hit.transcript, from: start)
                        } label: {
                            Text(timecode)
                                .font(Theme.mono).monospacedDigit()
                                .foregroundStyle(playable ? Theme.textSecondary : Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable)
                    }
                    Text(snippet.text)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .hoverHighlight(rowID)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// Analysis state for a transcript.
///
/// Queued, in progress, completed-with-results and completed-without-results are
/// four distinct states. Rendering them identically makes it impossible to
/// determine whether analysis has run.
struct LearningBadge: View {
    let transcript: Transcript
    @ObservedObject private var scan = LearningScan.shared

    var body: some View {
        if scan.analysing == transcript.id {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 10, height: 10)
                Text("reading")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.live)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.live.opacity(0.12)))
            .transition(.opacity)
        } else if transcript.analyzedAt == nil {
            Chip(text: "queued", tint: Theme.warning)
                .transition(.opacity)
        } else if transcript.analysisFindings > 0 {
            Chip(text: "learned \(transcript.analysisFindings)", tint: Theme.live)
                .transition(.opacity)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                Text("checked")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(Theme.textTertiary)
            .help("Read by the learning pass — nothing new in it")
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.medium(10.5))
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

private struct JobCard: View {
    let job: FileTranscriptionService.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(job.name)
                    .font(Theme.medium(12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Int(job.progress * 100))%")
                    .font(Theme.mono).monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hover)
                    Capsule().fill(Theme.live).frame(width: max(3, geo.size.width * job.progress))
                }
            }
            .frame(height: 3)
            .animation(Theme.quick, value: job.progress)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.live.opacity(0.3), lineWidth: 1))
    }
}

private struct TrashPrompt: View {
    let url: URL
    @ObservedObject private var files = FileTranscriptionService.shared

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.live)
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcript saved").font(Theme.medium(12.5)).foregroundStyle(Theme.textPrimary)
                Text("Done with \(url.lastPathComponent)?")
                    .font(Theme.body(11.5)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Keep It") { files.keepOriginal() }.buttonStyle(GhostButtonStyle())
            Button {
                files.trashOriginal()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 9.5, weight: .semibold))
                    Text("Move to Trash")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.border, lineWidth: 1))
    }
}

private struct FailureBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    @ObservedObject private var files = FileTranscriptionService.shared

    init(message: String, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(message).font(Theme.body(12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") {
                if let onDismiss { onDismiss() } else { files.dismissFailure() }
            }
            .buttonStyle(GhostButtonStyle(tint: Theme.danger))
        }
        .foregroundStyle(Theme.danger)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.danger.opacity(0.1)))
    }
}
