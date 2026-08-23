import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Qwen3 4B, downloaded on demand and run on this Mac's GPU through MLX.
///
/// Exists because Apple's on-device model has a 4,096-token context window, and
/// a one-hour meeting is roughly 12,000 tokens. That limit forces the summary
/// pipeline to read the transcript in fifteen pieces and stitch the results
/// together, which loses material at every seam. This model holds the whole
/// transcript at once, so the summary is written by something that has read all
/// of it.
///
/// Strictly optional. Nothing here is touched unless the summary backend is set
/// to it, and the application is fully functional without ever downloading it.
/// Like every other model in this application it runs locally; the download is
/// the only network access, and it carries no user content.
@MainActor
final class LocalLanguageModel: ObservableObject {

    static let shared = LocalLanguageModel()

    enum State: Equatable {
        case notLoaded
        /// Fraction complete, and a human-readable size so a multi-gigabyte
        /// fetch is never a bare spinner.
        case downloading(Double, String)
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }

        /// Determinate only while downloading. Generation has no meaningful
        /// percentage, and inventing one is worse than admitting it.
        var fraction: Double? {
            if case .downloading(let value, _) = self { return value }
            return nil
        }
    }

    @Published private(set) var state: State = .notLoaded

    /// Roughly what the weights occupy on disk, for the interface to quote
    /// before someone commits to fetching them.
    static let downloadSize = "2.5 GB"
    static let displayName = "Qwen3 4B"

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    private init() {}

    var isReady: Bool { container != nil }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return state == .loading
    }

    /// Human-readable state, for Settings.
    var statusText: String {
        switch state {
        case .notLoaded:
            return "Not downloaded. About \(Self.downloadSize), fetched once when a summary first needs it."
        case .downloading(let fraction, let detail):
            return "Downloading \(Self.displayName) — \(Int((fraction * 100).rounded()))%\(detail)"
        case .loading:
            return "Loading into memory…"
        case .ready:
            return "Ready. Runs on this Mac, offline."
        case .failed(let why):
            return why
        }
    }

    // MARK: - Loading

    /// Loads the model, downloading it first if necessary. Single-flight: a
    /// second caller awaits the first rather than starting a parallel download
    /// of several gigabytes.
    func load() async throws -> ModelContainer {
        if let container { return container }
        if let existing = loadTask { return try await existing.value }

        let task = Task { () throws -> ModelContainer in
            state = .downloading(0, "")
            do {
                let loaded = try await #huggingFaceLoadModelContainer(
                    configuration: LLMRegistry.qwen3_4b_4bit,
                    progressHandler: { progress in
                        // Delivered off the main actor, and often several times
                        // a second.
                        Task { @MainActor in
                            LocalLanguageModel.shared.report(progress)
                        }
                    }
                )
                state = .loading
                container = loaded
                state = .ready
                Log.app.info("local language model ready")
                return loaded
            } catch {
                state = .failed(Self.readable(error))
                Log.app.error("local model load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        loadTask = task
        defer { loadTask = nil }
        return try await task.value
    }

    /// Translates the downloader's `Progress` into something the interface can
    /// show. Byte counts are included because a percentage alone gives no sense
    /// of how long two and a half gigabytes will take.
    private func report(_ progress: Progress) {
        let fraction = progress.fractionCompleted
        var detail = ""
        if progress.totalUnitCount > 0 {
            let done = Self.bytes(progress.completedUnitCount)
            let total = Self.bytes(progress.totalUnitCount)
            detail = "  (\(done) of \(total))"
        }
        state = .downloading(fraction, detail)
    }

    private static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    /// Frees the weights. The model is several gigabytes resident, which is
    /// worth reclaiming on a machine that has other work to do.
    func unload() {
        container = nil
        state = .notLoaded
        Log.app.info("local language model unloaded")
    }

    // MARK: - Generation

    /// One question, one fresh session.
    ///
    /// Sessions are never reused across calls. A persistent session accumulates
    /// every previous transcript in the same window, which is the failure this
    /// model was adopted to avoid.
    /// - Parameter onChunk: called as text arrives. Generation over a whole
    ///   meeting takes about a minute, and a progress bar that cannot move for
    ///   that long is indistinguishable from a hang; streaming gives the
    ///   interface something true to show.
    func respond(
        instructions: String,
        prompt: String,
        onChunk: @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        let model = try await load()
        let session = ChatSession(model, instructions: instructions)
        // Qwen3 is a reasoning model. Thinking is suppressed for these tasks --
        // it costs generation time and the answer is what gets parsed.
        var accumulated = ""
        for try await chunk in session.streamResponse(to: prompt + "\n\n/no_think") {
            accumulated += chunk
            onChunk(Self.stripThinking(accumulated))
        }
        return Self.stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Qwen3 emits a <think> block ahead of its answer even when thinking is
    /// suppressed, and it is not part of the response.
    static func stripThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }

    private static func readable(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("network")
            || text.localizedCaseInsensitiveContains("internet")
            || text.localizedCaseInsensitiveContains("offline") {
            return "Couldn't download the model — check your connection and try again."
        }
        return "Couldn't load the model: \(text)"
    }
}
