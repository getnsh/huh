import Foundation

/// A correction that fired on a specific transcript.
struct AppliedCorrection: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var hear: String
    var write: String
    /// The literal text that was replaced, not the pattern. The exact match
    /// form is retained as evidence.
    var matched: String
}

/// A timestamped portion of a longer recording. Not produced for dictation;
/// required for navigating recordings of any length.
struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var start: TimeInterval
    var text: String

    var timecode: String {
        let total = Int(start.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum TranscriptSource: String, Codable {
    case dictation
    case file
}

struct Transcript: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    /// Straight from the engine, before the dictionary touched it.
    var raw: String
    /// The text that was inserted, or persisted in the case of file imports.
    var text: String
    var corrections: [AppliedCorrection] = []
    var engine: String = ""
    var duration: TimeInterval = 0

    var source: TranscriptSource = .dictation
    /// Filename, for file transcripts.
    var sourceName: String = ""
    /// Location of the source media, used for playback and cleanup.
    var sourcePath: String = ""
    var segments: [TranscriptSegment] = []
    /// How many filler words the cleanup pass dropped.
    var cleanupRemoved: Int = 0
    /// Summary produced by the on-device model. Empty until requested.
    var summary: String = ""
    var summaryDate: Date?

    /// When the analysis pass completed for this transcript. A nil value means
    /// queued, which is distinct from analysed-with-no-results.
    var analyzedAt: Date?
    /// Number of actionable results this transcript produced.
    var analysisFindings: Int = 0

    var wasCorrected: Bool { !corrections.isEmpty }

    var wordCount: Int {
        text.split { $0 == " " || $0 == "\n" }.count
    }

    // Swift's synthesised decoder throws on a missing key rather than falling
    // back to a property's default value. Adding a field would therefore render
    // every previously persisted transcript undecodable. Decoding leniently
    // keeps stored history readable across schema changes.
    enum CodingKeys: String, CodingKey {
        case id, date, raw, text, corrections, engine, duration
        case source, sourceName, sourcePath, segments, cleanupRemoved, summary, summaryDate
        case analyzedAt, analysisFindings
    }

    init(raw: String,
         text: String,
         corrections: [AppliedCorrection] = [],
         engine: String = "",
         duration: TimeInterval = 0,
         source: TranscriptSource = .dictation,
         sourceName: String = "",
         sourcePath: String = "",
         segments: [TranscriptSegment] = [],
         cleanupRemoved: Int = 0) {
        self.raw = raw
        self.text = text
        self.corrections = corrections
        self.engine = engine
        self.duration = duration
        self.source = source
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.segments = segments
        self.cleanupRemoved = cleanupRemoved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        corrections = try c.decodeIfPresent([AppliedCorrection].self, forKey: .corrections) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        source = try c.decodeIfPresent(TranscriptSource.self, forKey: .source) ?? .dictation
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        cleanupRemoved = try c.decodeIfPresent(Int.self, forKey: .cleanupRemoved) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summaryDate = try c.decodeIfPresent(Date.self, forKey: .summaryDate)
        analyzedAt = try c.decodeIfPresent(Date.self, forKey: .analyzedAt)
        analysisFindings = try c.decodeIfPresent(Int.self, forKey: .analysisFindings) ?? 0
    }
}
