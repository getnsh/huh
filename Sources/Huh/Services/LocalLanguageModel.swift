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
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
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

    /// Human-readable state, for Settings.
    var statusText: String {
        switch state {
        case .notLoaded:
            return "Not downloaded. About \(Self.downloadSize), fetched once when a summary first needs it."
        case .downloading(let fraction):
            return "Downloading… \(Int((fraction * 100).rounded()))%"
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
            state = .downloading(0)
            do {
                let loaded = try await #huggingFaceLoadModelContainer(
                    configuration: LLMRegistry.qwen3_4b_4bit
                )
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
    func respond(instructions: String, prompt: String) async throws -> String {
        let model = try await load()
        let session = ChatSession(model, instructions: instructions)
        // Qwen3 is a reasoning model. Thinking is suppressed for these tasks --
        // it costs generation time and the answer is what gets parsed.
        let reply = try await session.respond(to: prompt + "\n\n/no_think")
        return Self.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
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
