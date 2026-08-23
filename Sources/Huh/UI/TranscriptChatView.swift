import SwiftUI

/// Questions and answers about one recording.
///
/// Presented directly beneath the summary because it is the same act continued:
/// the summary answers "what was this", and this answers everything after that.
///
/// The interface is deliberately honest about its limits. Answers cite the
/// timecodes they were drawn from, and a question the recording cannot answer
/// gets a plain admission rather than a confident guess — a small model working
/// from one transcript has nothing else to offer, and pretending otherwise
/// would make every other answer untrustworthy.
struct TranscriptChatCard: View {
    let transcript: Transcript

    @ObservedObject private var chat = TranscriptChat.shared
    @ObservedObject private var intelligence = ModelAvailability.shared
    @ObservedObject private var ui = UIState.shared

    private var messages: [TranscriptChat.Message] { chat.messages(for: transcript.id) }
    private var thinking: Bool { chat.isThinking(about: transcript.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.live)
                SectionLabel("Ask about this")
                Spacer(minLength: 0)
                if !messages.isEmpty {
                    Button("Clear") { chat.clear(transcript.id) }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            if !intelligence.isReady {
                IntelligenceNotice(compact: true)
            } else {
                if messages.isEmpty {
                    Text("Answers come from this recording only, and run on this Mac.")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.textTertiary)

                    FlowRow(spacing: 6) {
                        ForEach(TranscriptChat.starters(for: transcript), id: \.self) { starter in
                            Button(starter) { chat.ask(starter, about: transcript) }
                                .buttonStyle(GhostButtonStyle(tint: Theme.live))
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            ChatBubble(message: message)
                        }
                    }
                }

                if thinking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the relevant parts…")
                            .font(Theme.body(11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                composer
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.borderSoft, lineWidth: 1))
        .animation(Theme.spring, value: messages)
        .animation(Theme.quick, value: thinking)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask a question about this recording…", text: $chat.draft)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.base))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(Theme.borderSoft, lineWidth: 1)
                )
                .onSubmit { chat.ask(chat.draft, about: transcript) }
                .disabled(thinking)

            Button {
                chat.ask(chat.draft, about: transcript)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.live))
            .disabled(thinking || chat.draft.trimmed.isEmpty)
        }
    }
}

private struct ChatBubble: View {
    let message: TranscriptChat.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if message.role == .you {
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 40)
                    Text(message.text)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.hover)
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if message.isOutOfScope {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            Text(message.text)
                                .font(Theme.body(12.5))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        MarkdownBlock(text: message.text)
                    }

                    if !message.sources.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Theme.textTertiary)
                            Text("From \(message.sources.prefix(4).joined(separator: ", "))\(message.sources.count > 4 ? "…" : "")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
