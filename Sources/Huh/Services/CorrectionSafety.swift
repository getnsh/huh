import Foundation

/// Validates a correction before it is saved.
///
/// Guards against over-broad rules: a single-word trigger that also matches an
/// ordinary English word will silently rewrite unrelated text everywhere it
/// occurs, and the damage is not obvious until much later.
///
/// The check is deliberately empirical rather than heuristic. It compiles the
/// exact pattern the correction engine will use and evaluates it against a
/// corpus of common words and well-known proper nouns, reporting every actual
/// collision.
enum CorrectionSafety {

    struct Warning: Identifiable, Hashable {
        var id: String { message }
        let message: String
        let severity: Severity

        enum Severity { case caution, danger }
    }

    static func check(hear: String, write: String) -> [Warning] {
        var warnings: [Warning] = []
        let trigger = hear.trimmed

        guard !trigger.isEmpty else {
            return [Warning(message: "Enter the text you want corrected.", severity: .danger)]
        }
        guard !write.trimmed.isEmpty else {
            return [Warning(message: "Enter what it should be replaced with.", severity: .danger)]
        }
        if trigger.compare(write.trimmed, options: .caseInsensitive) == .orderedSame {
            warnings.append(Warning(
                message: "This replaces the text with itself — it will never change anything.",
                severity: .caution))
        }

        guard let regex = CorrectionEngine.regex(for: trigger) else {
            return [Warning(message: "This can't be turned into a usable pattern.", severity: .danger)]
        }

        let collisions = corpus.filter { word in
            let range = NSRange(location: 0, length: (word as NSString).length)
            return regex.firstMatch(in: word, options: [], range: range) != nil
        }

        if !collisions.isEmpty {
            let sample = collisions.prefix(4).joined(separator: ", ")
            let more = collisions.count > 4 ? " and \(collisions.count - 4) more" : ""
            warnings.append(Warning(
                message: "This also matches everyday text: \(sample)\(more). Every one of those would be rewritten to “\(write.trimmed)”.",
                severity: .danger))
        }

        if trigger.count < 4 && collisions.isEmpty {
            warnings.append(Warning(
                message: "Very short triggers fire more often than you expect. Consider adding a second word.",
                severity: .caution))
        }

        let wordCount = trigger.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount == 1 && collisions.isEmpty && trigger.count >= 4 {
            warnings.append(Warning(
                message: "Single-word trigger. It only fires as a whole word, so “\(trigger)” inside a longer word is safe.",
                severity: .caution))
        }

        return warnings
    }

    /// Common English words plus frequently dictated proper nouns. Kept small
    /// deliberately: this is evaluated on every keystroke in the editor.
    static let corpus: [String] = [
        // High-frequency English
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "it", "for", "not", "on",
        "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they",
        "we", "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there",
        "their", "what", "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take", "people",
        "into", "year", "your", "good", "some", "could", "them", "see", "other", "than",
        "then", "now", "look", "only", "come", "its", "over", "think", "also", "back",
        "after", "use", "two", "how", "our", "work", "first", "well", "way", "even", "new",
        "want", "because", "any", "these", "give", "day", "most", "us", "read", "write",
        "run", "call", "send", "open", "close", "start", "stop", "build", "ship", "fix",
        "test", "check", "review", "meet", "meeting", "email", "note", "notes", "team",
        "project", "product", "design", "code", "data", "file", "files", "app", "apps",
        "user", "users", "client", "server", "cloud", "load", "save", "print", "sound",
        "voice", "text", "word", "words", "line", "page", "site", "link", "list", "board",
        "sheet", "doc", "docs", "plan", "task", "issue", "bug", "story", "sprint", "release",
        "branch", "merge", "commit", "push", "pull", "deploy", "log", "logs", "error",
        "warning", "model", "models", "token", "tokens", "prompt", "agent", "chat",
        // Proper nouns that share prefixes with common corrections
        "Cloudflare", "iCloud", "CloudKit", "Soundcloud", "Claude", "Clod", "Cloudy",
        "Google", "Apple", "Amazon", "Microsoft", "Meta", "OpenAI", "Anthropic", "GitHub",
        "Slack", "Notion", "Figma", "Linear", "Vercel", "Supabase", "Stripe", "Postgres",
        "Docker", "Kubernetes", "Swift", "Python", "Rust", "Node", "React", "Next"
    ]
}
