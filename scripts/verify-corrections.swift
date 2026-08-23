// Standalone check of the correction pass. Compiles the real CorrectionEngine
// against the real models — no mocks, no duplicated logic.
//   ./scripts/verify-corrections.sh
import Foundation

var failures = 0

func expect(_ input: String, _ pairs: [(String, String)], equals expected: String,
            _ label: String, file: StaticString = #file, line: UInt = #line) {
    let corrections = pairs.map { CorrectionPair(hear: $0.0, write: $0.1) }
    let result = CorrectionEngine.apply(input, corrections: corrections)
    if result.text == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        print("       input:    \(input)")
        print("       expected: \(expected)")
        print("       actual:   \(result.text)")
        failures += 1
    }
}

print("glue tolerance")
expect("I use cloud code daily", [("cloud code", "Claude Code")],
       equals: "I use Claude Code daily", "spaced")
expect("I use CloudCode daily", [("cloud code", "Claude Code")],
       equals: "I use Claude Code daily", "glued")
expect("I use Cloud-Code daily", [("cloud code", "Claude Code")],
       equals: "I use Claude Code daily", "hyphenated")
expect("i use CLOUD   CODE daily", [("cloud code", "Claude Code")],
       equals: "i use Claude Code daily", "case + extra whitespace")

print("must not corrupt real words")
expect("Cloudflare fronts our cloud storage", [("cloud code", "Claude Code")],
       equals: "Cloudflare fronts our cloud storage", "Cloudflare and bare cloud untouched")
expect("Cloudflare is fine", [("cloud", "Claude")],
       equals: "Cloudflare is fine", "single-word trigger stays out of longer words")
expect("iCloud backup", [("cloud", "Claude")],
       equals: "iCloud backup", "no match inside iCloud")
expect("the cloud is fine", [("cloud", "Claude")],
       equals: "the Claude is fine", "but does fire on the whole word")

print("longest match wins")
expect("run cloud code cli now", [("cloud code", "Claude Code"), ("cloud code cli", "Claude Code CLI")],
       equals: "run Claude Code CLI now", "longer trigger beats shorter")

print("no cascade corruption")
expect("cloud code is good", [("cloud code", "Claude Code"), ("code", "Kode")],
       equals: "Claude Code is good", "second rule can't eat the first rule's output")

print("punctuation boundaries")
expect("(cloud code) — cloud code!", [("cloud code", "Claude Code")],
       equals: "(Claude Code) — Claude Code!", "brackets and punctuation")

print("audit trail")
let audit = CorrectionEngine.apply("CloudCode and cloud code",
                                   corrections: [CorrectionPair(hear: "cloud code", write: "Claude Code")])
if audit.applied.count == 2, audit.applied[0].matched == "CloudCode", audit.applied[1].matched == "cloud code" {
    print("  ok   reports both matches with the literal text each one replaced")
} else {
    print("  FAIL audit trail: \(audit.applied.map(\.matched))")
    failures += 1
}

print("safety warnings")
let risky = CorrectionSafety.check(hear: "cloud", write: "Claude")
if risky.contains(where: { $0.severity == .danger }) {
    print("  ok   warns on 'cloud' (collides with the everyday word)")
} else {
    print("  FAIL no danger warning for 'cloud'")
    failures += 1
}
let safe = CorrectionSafety.check(hear: "cloud code", write: "Claude Code")
if !safe.contains(where: { $0.severity == .danger }) {
    print("  ok   no danger warning for 'cloud code'")
} else {
    print("  FAIL false alarm on 'cloud code': \(safe.map(\.message))")
    failures += 1
}

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
