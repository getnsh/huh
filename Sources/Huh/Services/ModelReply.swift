import Foundation

/// Parsing and validation of the on-device model's plain-text replies.
///
/// Kept pure, dependency-free and separate from the services that make the
/// requests, for two reasons. It is the part most likely to be wrong — a small
/// model's output drifts in format and occasionally in sanity — and it is the
/// only part that can be tested without a model present. Everything here is
/// exercised directly by `scripts/verify-extraction.sh` against the shipping
/// source.
///
/// Structured generation would be preferable to text parsing, but the
/// `@Generable` macro is unavailable in a Command Line Tools toolchain, which
/// this project builds under by design.
enum ModelReply {

    // MARK: - Classification of unrecognised words

    enum Kind: Equatable {
        /// A person. The value is the canonical spelling, which may equal the
        /// token when the recogniser spelled it correctly.
        case person(String)
        /// Jargon or a product name, already spelled correctly.
        case term
        /// An ordinary word heard wrong. The value is the replacement.
        case fix(String)
        /// No confident answer. The correct outcome most of the time.
        case skip
    }

    struct Answer: Equatable {
        var token: String
        var kind: Kind
    }

    /// Number of identical answers that marks a batch as collapsed.
    ///
    /// Mode collapse is the characteristic failure of a small model asked
    /// several similar questions at once: it settles on one answer and gives it
    /// to everything. Detecting it is cheaper and more reliable than prompting
    /// against it.
    static let collapseLimit = 3

    static func normalise(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Parses `word | KIND | answer` lines.
    ///
    /// Answers for words that were not asked about are discarded, as are
    /// duplicates, implausible replacements, and collapsed batches.
    static func classifications(_ raw: String, candidates: [String]) -> [Answer] {
        let known = Dictionary(
            candidates.map { (normalise($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var out: [Answer] = []
        var seen = Set<String>()

        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|").map { $0.trimmed }
            guard parts.count >= 2 else { continue }

            let key = normalise(
                parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•0123456789."))
            )
            guard let token = known[key], seen.insert(key).inserted else { continue }

            let kind = parts[1].uppercased()
            var value = parts.count >= 3 ? parts[2] : ""
            // Replies occasionally trail into commentary.
            value = value.components(separatedBy: CharacterSet(charactersIn: ".;(")).first?.trimmed ?? value
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—\"'“”"))

            if kind.hasPrefix("NAME") {
                guard let name = validated(value, against: token, allowingIdentity: true) else { continue }
                out.append(Answer(token: token, kind: .person(name)))
            } else if kind.hasPrefix("TERM") {
                out.append(Answer(token: token, kind: .term))
            } else if kind.hasPrefix("FIX") {
                guard let fixed = validated(value, against: token, allowingIdentity: false) else { continue }
                out.append(Answer(token: token, kind: .fix(fixed)))
            } else {
                out.append(Answer(token: token, kind: .skip))
            }
        }

        return rejectingCollapse(out)
    }

    /// A replacement is accepted only if it could plausibly be a mishearing of
    /// the original. A small model handed a reference list will otherwise map
    /// unrelated words onto a listed name with complete confidence.
    ///
    /// A name may equal its token: the recogniser spelling a name correctly is
    /// still worth knowing, because the person is worth remembering.
    static func validated(_ value: String, against token: String, allowingIdentity: Bool) -> String? {
        let clean = value.trimmed
        guard !clean.isEmpty, clean.uppercased() != "SKIP", clean != "-" else { return nil }
        guard clean.count <= token.count * 3 + 12 else { return nil }
        guard clean.first?.isLetter == true else { return nil }

        if clean.compare(token, options: .caseInsensitive) == .orderedSame {
            return allowingIdentity ? clean : nil
        }
        guard EditDistance.isPlausibleCorrection(from: token, to: clean) else { return nil }
        return clean
    }

    static func rejectingCollapse(_ answers: [Answer]) -> [Answer] {
        var counts: [String: Int] = [:]
        for answer in answers {
            switch answer.kind {
            case .person(let value), .fix(let value):
                counts[value.lowercased(), default: 0] += 1
            default:
                break
            }
        }
        return answers.filter { answer in
            switch answer.kind {
            case .person(let value), .fix(let value):
                return (counts[value.lowercased()] ?? 0) < collapseLimit
            default:
                return true
            }
        }
    }

    // MARK: - Meeting observations

    enum ObservationKind: String, CaseIterable {
        case topic = "TOPIC"
        case decision = "DECISION"
        case action = "ACTION"
        case question = "QUESTION"
        case person = "PERSON"
    }

    struct Observation: Hashable {
        var kind: ObservationKind
        var text: String
    }

    /// Parses `LABEL: text` lines, tolerating the numbering and bullet
    /// characters models add unprompted.
    static func observations(_ raw: String) -> [Observation] {
        var out: [Observation] = []
        for line in raw.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•0123456789."))
            guard let colon = cleaned.firstIndex(of: ":") else { continue }
            let label = String(cleaned[cleaned.startIndex..<colon]).trimmed.uppercased()
            guard let kind = ObservationKind(rawValue: label) else { continue }
            let text = String(cleaned[cleaned.index(after: colon)...]).trimmed
            guard text.count > 1 else { continue }
            out.append(Observation(kind: kind, text: text))
        }
        return out
    }

    /// Collapses repetition without a model.
    ///
    /// A topic raised three times over a recording yields three near-identical
    /// observations, and a model asked to merge them will also quietly reword
    /// them. Edit distance is exact, free, and cannot paraphrase.
    static func consolidate(_ observations: [Observation]) -> [Observation] {
        var out: [Observation] = []
        for observation in observations {
            let text = observation.text
            guard text.count > 1 else { continue }
            let duplicate = out.contains { existing in
                existing.kind == observation.kind
                    && (existing.text.compare(text, options: .caseInsensitive) == .orderedSame
                        || EditDistance.normalised(existing.text.lowercased(), text.lowercased()) < 0.25)
            }
            if !duplicate { out.append(observation) }
        }
        return out
    }

    static func format(_ observations: [Observation], excluding: Set<ObservationKind>) -> String {
        observations
            .filter { !excluding.contains($0.kind) }
            .map { "\($0.kind.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }
}
