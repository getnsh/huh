import Foundation

/// Token accounting for Apple's on-device language model.
///
/// The model exposes a context window of 4,096 tokens per session, and that
/// budget covers everything the session sees: the instructions, every prompt,
/// and the response as it is generated. Overrunning it throws
/// `exceededContextWindowSize`, after which the session cannot respond at all.
///
/// Every prompt in this application is therefore sized before it is sent rather
/// than after it fails. Length is estimated from character count: Apple
/// documents roughly three to four characters per token for Latin scripts, and
/// the lower bound is used here because over-estimating a prompt's cost is the
/// cheap direction to be wrong in.
enum TokenBudget {

    /// Per-session context window of the on-device model.
    static let contextWindow = 4096

    /// Deliberately pessimistic. See the note above.
    static let charactersPerToken = 3.0

    /// Proportion of the window left unused, absorbing the error in the
    /// estimate above.
    static let headroom = 0.10

    /// Tokens available once headroom is deducted.
    static var usableWindow: Int { Int(Double(contextWindow) * (1 - headroom)) }

    static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / charactersPerToken).rounded(.up))
    }

    static func characters(forTokens tokens: Int) -> Int {
        Int(Double(max(0, tokens)) * charactersPerToken)
    }

    /// Words that fit in a token allowance. A typical English word plus its
    /// trailing space costs about two tokens at the ratio above.
    static func words(forTokens tokens: Int) -> Int {
        max(1, tokens / 2)
    }

    /// Tokens left for input after instructions and the anticipated response
    /// are accounted for.
    static func inputAllowance(instructions: String, response: Int) -> Int {
        max(0, usableWindow - estimate(instructions) - response)
    }

    /// Whether a request is expected to fit. Used as an assertion at the point
    /// a prompt is assembled, so an oversized prompt is caught by the code that
    /// built it rather than by the model.
    static func fits(instructions: String, prompt: String, response: Int) -> Bool {
        estimate(instructions) + estimate(prompt) + response <= usableWindow
    }

    /// Truncates on a word boundary so a clipped prompt never ends mid-token.
    static func clip(_ text: String, toTokens tokens: Int) -> String {
        let limit = characters(forTokens: tokens)
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        let head = text[text.startIndex..<cut]
        if let space = head.lastIndex(of: " ") {
            return String(head[head.startIndex..<space])
        }
        return String(head)
    }
}
