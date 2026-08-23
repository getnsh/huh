// Checks the cleanup pass against real transcript wreckage — and, more
// importantly, against sentences it must NOT touch.
import Foundation

var failures = 0

func expect(_ input: String, _ level: CleanupLevel, equals expected: String, _ label: String) {
    let result = TextCleanup.apply(input, level: level)
    if result.text == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        print("       in:       \(input)")
        print("       expected: \(expected)")
        print("       actual:   \(result.text)")
        failures += 1
    }
}

print("fillers")
expect("Uh, you remember the billing sync app issue.", .standard,
       equals: "You remember the billing sync app issue.", "leading uh")
expect("So that's, um, something we need to kick off.", .standard,
       equals: "So that's, something we need to kick off.", "mid-sentence um")
expect("I mean, ah, right.", .standard, equals: "I mean, right.", "ah")

print("stutters")
expect("Yeah, yeah, yeah. Okay.", .standard, equals: "Yeah. Okay.", "tripled yeah")
expect("No no, that's fine.", .standard, equals: "No, that's fine.", "doubled no")
expect("So so so we should ship it.", .standard, equals: "So we should ship it.", "tripled so")

print("must not damage real language")
expect("I like this like a lot.", .standard, equals: "I like this like a lot.", "'like' is never a filler here")
expect("The report that had had errors was fixed.", .standard,
       equals: "The report that had had errors was fixed.", "doubled 'had' is grammar, not a stutter")
expect("Ahmet and Erika are on the call.", .standard,
       equals: "Ahmet and Erika are on the call.", "'ah' and 'er' inside names survive")
expect("Summarise the umbrella policy.", .standard,
       equals: "Summarise the umbrella policy.", "'um' inside words survives")
expect("Uh-huh, understood.", .standard, equals: "Uh-huh, understood.", "hyphenated uh-huh is a word")

print("off does nothing")
expect("Uh, yeah, yeah, yeah.", .off, equals: "Uh, yeah, yeah, yeah.", "level off")

print("aggressive")
expect("You know, we basically shipped it.", .aggressive, equals: "We shipped it.", "hedges dropped")
expect("You know, we basically shipped it.", .standard,
       equals: "You know, we basically shipped it.", "standard leaves hedges alone")

print("counting")
let counted = TextCleanup.apply("Uh, um, yeah, yeah, yeah.", level: .standard)
print(counted.removed > 0 ? "  ok   reports \(counted.summary)" : "  FAIL nothing counted")
if counted.removed == 0 { failures += 1 }

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
