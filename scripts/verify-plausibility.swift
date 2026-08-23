// Verifies that implausible corrections are rejected structurally, independent
// of language-model behaviour.
import Foundation

var failures = 0

func expect(_ heard: String, _ write: String, plausible: Bool, _ label: String) {
    let actual = EditDistance.isPlausibleCorrection(from: heard, to: write)
    let ratio = EditDistance.normalised(heard, write)
    if actual == plausible {
        print(String(format: "  ok   %-42@ (%.2f)", label, ratio))
    } else {
        print(String(format: "  FAIL %-42@ (%.2f) expected %@", label, ratio, plausible ? "plausible" : "rejected"))
        failures += 1
    }
}

print("genuine mis-transcriptions are accepted")
expect("superbase", "Supabase", plausible: true, "superbase -> Supabase")
expect("versal", "Vercel", plausible: true, "versal -> Vercel")
expect("gitub", "GitHub", plausible: true, "gitub -> GitHub")
expect("kubernetis", "Kubernetes", plausible: true, "kubernetis -> Kubernetes")
expect("Lickup", "ClickUp", plausible: true, "Lickup -> ClickUp")
expect("Jonathin", "Jonathan", plausible: true, "Jonathin -> Jonathan")

print("unrelated substitutions are rejected")
expect("Cornwall", "Prashant", plausible: false, "Cornwall -> unrelated name")
expect("Ninja", "Prashant", plausible: false, "Ninja -> unrelated name")
expect("Jera", "Prashant", plausible: false, "Jera -> unrelated name")
expect("FOSs", "Prashant", plausible: false, "FOSs -> unrelated name")
expect("Miraki", "Prashant", plausible: false, "Miraki -> unrelated name")

print("boundaries")
expect("abc", "abc", plausible: true, "identical")
expect("", "Something", plausible: false, "empty input")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
