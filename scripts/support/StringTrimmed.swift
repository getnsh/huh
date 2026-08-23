import Foundation

// `trimmed` ships in CorrectionEngine.swift, which pulls in the correction
// machinery this suite does not need. Declared here so the suite compiles the
// sources under test and nothing else.
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
