import AppKit
import Foundation

/// Hands a transcript to a chat assistant the user already pays for.
///
/// The third option when a meeting is too long for Apple's on-device model: not
/// every user wants a 2.5 GB download, and most already have ChatGPT or Claude
/// open in a tab. Those models have context windows measured in hundreds of
/// thousands of tokens, so an hour of speech is unremarkable to them.
///
/// This is the one path in the application where transcript text leaves the
/// machine, and it is deliberately manual: the text goes to the clipboard and
/// the browser opens. Nothing is transmitted by this application, there is no
/// API key to store, and the user pastes — and therefore sees — exactly what
/// they are sending.
enum SummaryHandoff {

    enum Provider: String, CaseIterable, Identifiable {
        case chatGPT
        case claude

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chatGPT: return "ChatGPT"
            case .claude:  return "Claude"
            }
        }

        var url: URL {
            switch self {
            case .chatGPT: return URL(string: "https://chatgpt.com/")!
            case .claude:  return URL(string: "https://claude.ai/new")!
            }
        }
    }

    /// The prompt asks for the same headings the on-device backends produce, so
    /// a summary made this way is interchangeable with one made locally.
    static func prompt(for transcript: Transcript) -> String {
        let body = transcript.segments.isEmpty
            ? transcript.text
            : transcript.segments.map { "[\($0.timecode)] \($0.text)" }.joined(separator: "\n")

        return """
            Below is a transcript of a meeting, produced by a speech recogniser. It is \
            imperfect: names may be misspelled and some sentences are garbled. Work only \
            from what is there — never invent a name, a date, an owner or a decision.

            Write it up under exactly these headings:

            ## In one line
            One sentence: what this was about and what came of it.

            ## What was discussed
            Three to five short bullets.

            ## Decisions
            Bullets. Only what was actually settled.

            ## Action items
            Bullets formatted "Owner — task". Write "Unassigned" when no owner is named.

            ## Open questions
            Bullets.

            Transcript:
            \(body)
            """
    }

    /// Copies the prompt and opens the provider. Two steps rather than one
    /// because there is no way to prefill a chat of this size through a URL,
    /// and pretending otherwise would silently truncate the meeting.
    static func send(_ transcript: Transcript, to provider: Provider) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt(for: transcript), forType: .string)
        NSWorkspace.shared.open(provider.url)
        Log.app.info("transcript prepared for \(provider.rawValue, privacy: .public)")
    }

    /// Rough size, so the interface can say what is about to be pasted.
    static func approximateTokens(_ transcript: Transcript) -> Int {
        TokenBudget.estimate(transcript.text)
    }
}
