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
expect("Zendisk", "Zendesk", plausible: true, "Zendisk -> Zendesk")
expect("Jonathin", "Jonathan", plausible: true, "Jonathin -> Jonathan")

print("unrelated substitutions are rejected")
expect("Riverbend", "Ashwin", plausible: false, "Riverbend -> unrelated name")
expect("Falcon", "Ashwin", plausible: false, "Falcon -> unrelated name")
expect("Terra", "Ashwin", plausible: false, "Terra -> unrelated name")
expect("PDFs", "Ashwin", plausible: false, "PDFs -> unrelated name")
expect("Solaris", "Ashwin", plausible: false, "Solaris -> unrelated name")

print("boundaries")
expect("abc", "abc", plausible: true, "identical")
expect("", "Something", plausible: false, "empty input")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
