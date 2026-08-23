// Verifies the parsing and validation applied to the on-device model's replies,
// and the token budgeting that keeps a prompt inside the model's context window.
//
// Every case here is a real failure mode observed from a small model: drifting
// reply formats, unsolicited numbering, answers for words that were never
// asked about, confident nonsense, and mode collapse onto a single answer.
import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

func label(_ answers: [ModelReply.Answer], _ index: Int) -> String {
    guard answers.indices.contains(index) else { return "<missing>" }
    return kindLabel(answers[index].kind)
}

func kindLabel(_ kind: ModelReply.Kind) -> String {
    switch kind {
    case .person(let name): return "person(\(name))"
    case .fix(let word):    return "fix(\(word))"
    case .term:             return "term"
    case .skip:             return "skip"
    }
}

// MARK: - Classification

print("well-formed replies parse")
do {
    let reply = """
        Lickup | NAME | ClickUp
        superbase | TERM | -
        bundo | FIX | bundle
        critese | SKIP | -
        """
    let answers = ModelReply.classifications(reply, candidates: ["Lickup", "superbase", "bundo", "critese"])
    check(answers.count == 4, "four answers for four words")
    check(label(answers, 0) == "person(ClickUp)", "NAME carries the corrected spelling")
    check(label(answers, 1) == "term", "TERM needs no answer")
    check(label(answers, 2) == "fix(bundle)", "FIX carries the replacement")
    check(label(answers, 3) == "skip", "SKIP is preserved as an answer")
}

// A near-miss typo is not a dictionary entry. "teh" for "the" is a two-edit
// change across a three-letter word, which scores as unrelated and is dropped —
// exactly the outcome wanted, since a rule rewriting "teh" everywhere is worse
// than the occasional typo it fixes.
print("ordinary typos are not turned into rules")
do {
    let answers = ModelReply.classifications("teh | FIX | the", candidates: ["teh"])
    check(answers.isEmpty, "teh -> the is rejected as implausible")
}

print("a name spelled correctly is still a name")
do {
    let answers = ModelReply.classifications("Katherine | NAME | Katherine", candidates: ["Katherine"])
    check(label(answers, 0) == "person(Katherine)", "identity accepted for NAME")
}

print("an unchanged word is not a fix")
do {
    let answers = ModelReply.classifications("colour | FIX | colour", candidates: ["colour"])
    check(answers.isEmpty, "identity rejected for FIX")
}

print("models decorate their output")
do {
    let reply = """
        Here you go:
        1. Jonathin | NAME | Jonathan
        - versal | NAME | Vercel
        * gitub | TERM | -
        """
    let answers = ModelReply.classifications(reply, candidates: ["Jonathin", "versal", "gitub"])
    check(answers.count == 3, "numbering, bullets and preamble are tolerated")
    check(label(answers, 0) == "person(Jonathan)", "numbered line parsed")
}

print("trailing commentary is trimmed")
do {
    let answers = ModelReply.classifications(
        "Lickup | NAME | ClickUp. This is a project management tool.",
        candidates: ["Lickup"]
    )
    check(label(answers, 0) == "person(ClickUp)", "explanation dropped")
}

print("answers for words that were not asked about are discarded")
do {
    let answers = ModelReply.classifications(
        "Kubernetes | NAME | Kubernetes\nLickup | NAME | ClickUp",
        candidates: ["Lickup"]
    )
    check(answers.count == 1, "only the requested word survives")
}

print("duplicate lines for one word are ignored")
do {
    let answers = ModelReply.classifications(
        "Lickup | NAME | ClickUp\nLickup | NAME | Lockup",
        candidates: ["Lickup"]
    )
    check(answers.count == 1, "first answer wins")
}

print("implausible answers are rejected")
do {
    let answers = ModelReply.classifications("Cornwall | NAME | Prashant", candidates: ["Cornwall"])
    check(answers.isEmpty, "an answer that sounds nothing like the word is dropped")
}

print("mode collapse is detected")
do {
    let reply = """
        Prashent | NAME | Prashant
        Prashint | NAME | Prashant
        Proshant | NAME | Prashant
        """
    let answers = ModelReply.classifications(reply, candidates: ["Prashent", "Prashint", "Proshant"])
    check(answers.isEmpty, "one answer given to three words is discarded entirely")
}

print("two collapsed answers are still allowed")
do {
    let reply = """
        Prashent | NAME | Prashant
        Prashint | NAME | Prashant
        """
    let answers = ModelReply.classifications(reply, candidates: ["Prashent", "Prashint"])
    check(answers.count == 2, "genuine variants of one name survive")
}

print("malformed lines are skipped rather than fatal")
do {
    let reply = "I'm not sure about any of these.\nLickup NAME ClickUp\nLickup | NAME | ClickUp"
    let answers = ModelReply.classifications(reply, candidates: ["Lickup"])
    check(answers.count == 1, "prose and separator-less lines are ignored")
}

// MARK: - Observations

print("meeting observations parse")
do {
    let reply = """
        TOPIC: pricing for the new tier
        DECISION: ship the beta on Friday
        ACTION: Priya — draft the changelog
        QUESTION: who owns the migration?
        PERSON: Priya
        Some stray commentary the model added.
        """
    let observations = ModelReply.observations(reply)
    check(observations.count == 5, "five labelled lines, commentary dropped")
    check(observations.count > 2 && observations[1].kind == .decision, "labels map to kinds")
    check(observations.count > 2 && observations[2].text == "Priya — draft the changelog", "text preserved verbatim")
}

print("numbered observations parse")
do {
    let observations = ModelReply.observations("1. DECISION: ship on Friday\n- TOPIC: pricing")
    check(observations.count == 2, "numbering and bullets tolerated")
}

print("near-duplicate observations are collapsed")
do {
    let observations = ModelReply.consolidate([
        .init(kind: .decision, text: "Ship the beta on Friday"),
        .init(kind: .decision, text: "ship the beta on friday"),
        .init(kind: .decision, text: "Ship the beta on Friday."),
        .init(kind: .decision, text: "Postpone the pricing change")
    ])
    check(observations.count == 2, "restatements of one decision become one")
}

print("the same words under different labels are kept apart")
do {
    let observations = ModelReply.consolidate([
        .init(kind: .decision, text: "Ship the beta on Friday"),
        .init(kind: .action, text: "Ship the beta on Friday")
    ])
    check(observations.count == 2, "a decision and an action are not duplicates")
}

// MARK: - Token budget

print("token budgeting")
do {
    check(TokenBudget.contextWindow == 4096, "the documented window is 4,096 tokens")
    check(TokenBudget.usableWindow < TokenBudget.contextWindow, "headroom is reserved")

    let instructions = String(repeating: "a", count: 300)
    let allowance = TokenBudget.inputAllowance(instructions: instructions, response: 300)
    check(allowance > 0, "an allowance remains after instructions and response")
    check(
        allowance + TokenBudget.estimate(instructions) + 300 <= TokenBudget.usableWindow,
        "the allowance plus its reservations stays inside the window"
    )

    let long = String(repeating: "word ", count: 5000)
    check(!TokenBudget.fits(instructions: instructions, prompt: long, response: 300), "an oversized prompt is refused")

    let clipped = TokenBudget.clip(long, toTokens: 100)
    check(TokenBudget.estimate(clipped) <= 100, "clipping respects the token limit")
    check(!clipped.hasSuffix("wor"), "clipping lands on a word boundary")

    let short = "already short"
    check(TokenBudget.clip(short, toTokens: 100) == short, "text inside the limit is untouched")
}

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
