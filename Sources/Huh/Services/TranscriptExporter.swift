import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export and clipboard formats for transcripts.
///
/// The Google Docs path writes rich text to the pasteboard and opens a blank
/// document rather than using the Drive API. This avoids an OAuth flow, a cloud
/// project, and a consent screen while producing the same formatted result.
/// Plain text is written to the pasteboard alongside the rich text, so pasting
/// into other targets behaves normally.
enum TranscriptExporter {

    enum Format: String, CaseIterable, Identifiable {
        case plain
        case timestamped
        case markdown
        case srt
        case vtt

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plain:       return "Plain Text"
            case .timestamped: return "With Timestamps"
            case .markdown:    return "Markdown"
            case .srt:         return "Subtitles (.srt)"
            case .vtt:         return "WebVTT (.vtt)"
            }
        }

        var fileExtension: String {
            switch self {
            case .plain, .timestamped: return "txt"
            case .markdown:            return "md"
            case .srt:                 return "srt"
            case .vtt:                 return "vtt"
            }
        }
    }

    // MARK: - Text

    static func string(_ transcript: Transcript, as format: Format) -> String {
        let segments = transcript.segments

        switch format {
        case .plain:
            return transcript.text

        case .timestamped:
            guard !segments.isEmpty else { return transcript.text }
            return segments.map { "[\($0.timecode)]  \($0.text)" }.joined(separator: "\n")

        case .markdown:
            var out = "# \(title(for: transcript))\n\n"
            out += "*\(subtitle(for: transcript))*\n\n"
            if segments.isEmpty {
                out += transcript.text + "\n"
            } else {
                for segment in segments {
                    out += "**\(segment.timecode)** \(segment.text)\n\n"
                }
            }
            if transcript.wasCorrected {
                out += "\n---\n\n## Dictionary changes\n\n"
                for correction in transcript.corrections {
                    out += "- `\(correction.matched)` → **\(correction.write)**\n"
                }
            }
            return out

        case .srt:
            return subtitles(transcript, webVTT: false)

        case .vtt:
            return subtitles(transcript, webVTT: true)
        }
    }

    /// Segments carry a start time only, so each runs until the next begins.
    /// The final segment is given a nominal three-second duration.
    private static func subtitles(_ transcript: Transcript, webVTT: Bool) -> String {
        let segments = transcript.segments
        guard !segments.isEmpty else { return transcript.text }

        var out = webVTT ? "WEBVTT\n\n" : ""
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count
                ? segments[index + 1].start
                : segment.start + 3
            if !webVTT { out += "\(index + 1)\n" }
            out += "\(stamp(segment.start, webVTT: webVTT)) --> \(stamp(end, webVTT: webVTT))\n"
            out += "\(segment.text)\n\n"
        }
        return out
    }

    private static func stamp(_ seconds: TimeInterval, webVTT: Bool) -> String {
        let whole = Int(seconds)
        let millis = Int((seconds - Double(whole)) * 1000)
        let separator = webVTT ? "." : ","
        return String(format: "%02d:%02d:%02d\(separator)%03d",
                      whole / 3600, (whole % 3600) / 60, whole % 60, millis)
    }

    // MARK: - Rich text

    static func attributed(_ transcript: Transcript) -> NSAttributedString {
        let out = NSMutableAttributedString()

        out.append(NSAttributedString(string: title(for: transcript) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold)
        ]))
        out.append(NSAttributedString(string: subtitle(for: transcript) + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        if transcript.segments.isEmpty {
            out.append(NSAttributedString(string: transcript.text, attributes: [
                .font: NSFont.systemFont(ofSize: 12)
            ]))
        } else {
            for segment in transcript.segments {
                out.append(NSAttributedString(string: segment.timecode + "  ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                out.append(NSAttributedString(string: segment.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12)
                ]))
            }
        }
        return out
    }

    // MARK: - Actions

    static func copy(_ transcript: Transcript, as format: Format) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string(transcript, as: format), forType: .string)
    }

    /// Writes rich text and plain text to the pasteboard together.
    static func copyRich(_ transcript: Transcript) {
        let rich = attributed(transcript)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(string(transcript, as: .timestamped), forType: .string)
    }

    /// Copies formatted output and opens a blank Google Doc.
    static func sendToGoogleDocs(_ transcript: Transcript) {
        copyRich(transcript)
        if let url = URL(string: "https://docs.new") {
            NSWorkspace.shared.open(url)
        }
    }

    static func save(_ transcript: Transcript, as format: Format) {
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "\(suggestedFilename(transcript)).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try string(transcript, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Labels

    private static func title(for transcript: Transcript) -> String {
        if transcript.source == .file, !transcript.sourceName.isEmpty {
            return (transcript.sourceName as NSString).deletingPathExtension
        }
        return "Dictation"
    }

    private static func subtitle(for transcript: Transcript) -> String {
        var parts: [String] = [Self.dateFormatter.string(from: transcript.date)]
        if transcript.duration > 0 {
            let total = Int(transcript.duration.rounded())
            parts.append(total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60))
        }
        parts.append("\(transcript.wordCount) words")
        if transcript.wasCorrected {
            parts.append("\(transcript.corrections.count) dictionary correction\(transcript.corrections.count == 1 ? "" : "s")")
        }
        parts.append("transcribed on-device by \(Brand.name)")
        return parts.joined(separator: " · ")
    }

    private static func suggestedFilename(_ transcript: Transcript) -> String {
        let base = title(for: transcript)
        let safe = base.replacingOccurrences(of: "/", with: "-")
        return safe.isEmpty ? "transcript" : safe
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
