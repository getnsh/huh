import AVFoundation
import Foundation
import Speech

/// Transcribes a media file — a meeting recording, a voice memo, anything with
/// an audio track — using the same on-device engine as push-to-talk dictation.
///
/// Throughput is approximately 40x realtime on Apple silicon, so a one-hour
/// recording completes in roughly ninety seconds.
///
/// Two code paths are required because the relevant API was introduced across
/// two OS releases:
///
///  * macOS 27 provides `AssetInputSequenceProvider`, which accepts an `AVAsset`
///    directly, including video containers, and yields analyzer inputs.
///  * macOS 26 does not, so the audio track is exported to a temporary m4a and
///    processed through `analyzeSequence(from:)`.
///
/// The deployment target remains macOS 26.
enum FileTranscriber {

    struct Output {
        var segments: [TranscriptSegment]
        var text: String
        var duration: TimeInterval
    }

    enum Failure: LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple's speech transcriber isn't available on this Mac."
            case .unsupportedLocale(let id):
                return "\(id) isn't supported for transcription."
            case .noAudioTrack:
                return "That file has no audio track."
            case .exportFailed(let why):
                return "Couldn't read the audio out of that file: \(why)"
            }
        }
    }

    static func transcribe(
        url: URL,
        locale requestedLocale: Locale,
        bias: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Output {

        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw Failure.unsupportedLocale(requestedLocale.identifier)
        }

        // audioTimeRange yields per-segment timestamps, which are required for
        // a navigable transcript of a long recording.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let asset = AVURLAsset(url: url)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw Failure.noAudioTrack
        }
        Log.asr.info("file transcribe: \(url.lastPathComponent, privacy: .public), \(duration, privacy: .public)s")

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )

        // Contextual bias has no measurable effect on clean audio but is
        // inexpensive and may contribute on noisy recordings. The correction
        // pass is what actually enforces the dictionary.
        if !bias.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: bias]
            try? await analyzer.setContext(context)
        }

        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let start = CMTimeGetSeconds(result.range.start)
                let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(start: start, text: text))
                if duration > 0 {
                    // The analyzer exposes no progress callback, so progress is
                    // inferred from the timeline position of finalised results.
                    onProgress(min(1, max(0, start / duration)))
                }
            }
            return segments
        }

        if #available(macOS 27.0, *) {
            let provider = try await AssetInputSequenceProvider.provider(from: asset, compatibleWith: [transcriber])
            _ = try await analyzer.analyzeSequence(provider.analyzerInputs)
        } else {
            let extracted = try await extractAudio(from: asset)
            defer { try? FileManager.default.removeItem(at: extracted) }
            let audioFile = try AVAudioFile(forReading: extracted)
            _ = try await analyzer.analyzeSequence(from: audioFile)
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = try await collector.value
        onProgress(1)

        return Output(
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            duration: duration
        )
    }

    /// macOS 26 fallback: exports the audio track to a temporary m4a.
    private static func extractAudio(from asset: AVAsset) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.exportFailed("no export session")
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("huh-extract-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: out, as: .m4a)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
        return out
    }
}
