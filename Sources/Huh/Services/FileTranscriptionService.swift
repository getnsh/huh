import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Runs file transcription jobs and offers to remove the source file on
/// completion.
///
/// Jobs are serialised deliberately: concurrent transcriptions contend for the
/// same speech models, which slows both, and a single progress indicator cannot
/// accurately represent a parallel queue.
@MainActor
final class FileTranscriptionService: ObservableObject {

    static let shared = FileTranscriptionService()

    struct Job: Identifiable, Equatable {
        var id = UUID()
        var url: URL
        var progress: Double = 0
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var job: Job?
    @Published private(set) var failure: String?

    /// Set after a successful job so the interface can offer to move the source
    /// file to the Trash. Presented inline rather than as a modal: a job of this
    /// duration is frequently unattended, and a focus-stealing dialog guarding a
    /// destructive action invites accidental confirmation.
    @Published var completedOriginal: URL?
    @Published var completedTranscriptID: UUID?

    private init() {}

    static let acceptedTypes: [UTType] = [.movie, .video, .audio, .mpeg4Movie, .mpeg4Audio, .mp3, .wav, .aiff, .quickTimeMovie]

    static func isAcceptable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return acceptedTypes.contains { type.conforms(to: $0) }
    }

    var isRunning: Bool { job != nil }

    // MARK: - Running

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe a Recording"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url: url)
    }

    func start(url: URL) {
        guard job == nil else {
            failure = "Already transcribing \(job?.name ?? "a file")."
            return
        }
        guard Self.isAcceptable(url) else {
            failure = "\(url.lastPathComponent) isn't an audio or video file."
            return
        }

        failure = nil
        completedOriginal = nil
        completedTranscriptID = nil
        let job = Job(url: url)
        self.job = job

        Task {
            do {
                let dictionary = DictionaryStore.shared
                let output = try await FileTranscriber.transcribe(
                    url: url,
                    locale: AppSettings.shared.locale,
                    bias: Rules.bias,
                    onProgress: { [weak self] value in
                        Task { @MainActor in self?.updateProgress(value) }
                    }
                )

                guard !output.text.isEmpty else {
                    self.failure = "No speech found in \(url.lastPathComponent)."
                    self.job = nil
                    return
                }

                // File transcripts receive the same dictionary treatment as
                // dictated text.
                let corrected = CorrectionEngine.apply(output.text, corrections: Rules.corrections)
                dictionary.recordHits(corrected.applied)
                let level = AppSettings.shared.cleanupLevel
                let cleaned = TextCleanup.apply(corrected.text, level: level)

                // Corrections are applied to segments as well, so the
                // timestamped view stays consistent with the full text.
                let segments = output.segments.map { segment -> TranscriptSegment in
                    var copy = segment
                    let fixed = CorrectionEngine.apply(segment.text, corrections: Rules.corrections).text
                    copy.text = TextCleanup.apply(fixed, level: level).text
                    return copy
                }

                let transcript = Transcript(
                    raw: output.text,
                    text: cleaned.text,
                    corrections: corrected.applied,
                    engine: AppSettings.shared.engine.displayName,
                    duration: output.duration,
                    source: .file,
                    sourceName: url.lastPathComponent,
                    sourcePath: url.path,
                    segments: segments,
                    cleanupRemoved: cleaned.removed
                )
                HistoryStore.shared.add(transcript)

                self.job = nil
                self.completedTranscriptID = transcript.id
                self.completedOriginal = url
                Log.asr.info("file transcript saved: \(corrected.text.count, privacy: .public) chars, \(corrected.applied.count, privacy: .public) corrections")
            } catch {
                Log.asr.error("file transcribe failed: \(error.localizedDescription, privacy: .public)")
                self.failure = error.localizedDescription
                self.job = nil
            }
        }
    }

    private func updateProgress(_ value: Double) {
        guard var current = job else { return }
        current.progress = value
        job = current
    }

    // MARK: - Cleaning up the original

    /// Moves the source file to the Trash rather than unlinking it. The
    /// operation must be reversible: the transcript may prove inadequate, and a
    /// shared recording may not belong to this user.
    func trashOriginal() {
        guard let url = completedOriginal else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.failure = "Couldn't move it to the Trash: \(error.localizedDescription)"
                } else {
                    Log.app.info("moved original to Trash")
                }
                self?.completedOriginal = nil
            }
        }
    }

    func keepOriginal() {
        completedOriginal = nil
    }

    func dismissFailure() {
        failure = nil
    }
}
