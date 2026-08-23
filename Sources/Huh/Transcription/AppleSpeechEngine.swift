import AVFoundation
import Speech

/// On-device transcription via `SpeechAnalyzer` and `SpeechTranscriber`
/// (macOS 26+).
///
/// This is the default engine: models are provided by the system asset catalog,
/// so the application bundle carries no model data and there is no first-run
/// download to host. It streams volatile results, which the live overlay
/// requires.
///
/// The trade-off relative to a bundled model is that neither the model version
/// nor its punctuation behaviour is under application control.
final class AppleSpeechEngine: TranscriptionEngine {

    let id: EngineID = .appleSpeech
    var onPartial: ((String) -> Void)?
    var onPreparationStatus: ((String) -> Void)?
    var contextualStrings: [String] = []

    private let requestedLocale: Locale
    private var resolvedLocale: Locale?
    private var cachedFormat: AVAudioFormat?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?

    init(locale: Locale) {
        self.requestedLocale = locale
    }

    // MARK: - Preparation

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.engineUnavailable("Apple's speech transcriber isn't available on this Mac.")
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(requestedLocale.identifier)
        }
        resolvedLocale = locale

        let transcriber = makeTranscriber(locale: locale)

        // Pull down the locale's assets if this is the first run for it.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // macOS downloads the recogniser's language assets on first use for
            // a locale. This can take minutes on a slow connection, so report
            // progress rather than blocking silently.
            let progress = request.progress
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            Log.asr.info("downloading speech assets for \(locale.identifier, privacy: .public)")

            let reporter = Task { [weak self] in
                while !Task.isCancelled {
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    await MainActor.run {
                        self?.onPreparationStatus?("Downloading speech model for \(name)… \(percent)%")
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            defer { reporter.cancel() }

            try await request.downloadAndInstall()
            Log.asr.info("speech assets installed")
        }
        await MainActor.run { [weak self] in self?.onPreparationStatus?("") }

        cachedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Warm the model so the first utterance does not pay the load cost.
        let warm = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        try? await warm.prepareToAnalyze(in: cachedFormat)
        await warm.cancelAndFinishNow()
    }

    func preferredFormat() async throws -> AVAudioFormat {
        if let cachedFormat { return cachedFormat }
        guard let locale = resolvedLocale else { throw TranscriptionError.notPrepared }
        let transcriber = makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.notPrepared
        }
        cachedFormat = format
        return format
    }

    // MARK: - Utterance

    func beginUtterance() async throws {
        guard let locale = resolvedLocale else { throw TranscriptionError.notPrepared }

        let transcriber = makeTranscriber(locale: locale)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)

        self.continuation = continuation
        self.analyzer = analyzer

        // Mechanism one: bias the recogniser toward dictionary terms before
        // transcription. This is advisory and may be ignored by the model, which
        // is why the deterministic correction pass exists downstream.
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            do {
                try await analyzer.setContext(context)
                Log.asr.info("biasing with \(self.contextualStrings.count, privacy: .public) contextual strings")
            } catch {
                Log.asr.error("setContext failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Begin consuming results before starting analysis so that no early
        // result is dropped.
        resultsTask = Task { [weak self] in
            var finalized = AttributedString()
            for try await result in transcriber.results {
                if result.isFinal {
                    finalized += result.text
                    let text = String(finalized.characters)
                    await MainActor.run { [weak self] in self?.onPartial?(text) }
                } else {
                    let preview = String((finalized + result.text).characters)
                    await MainActor.run { [weak self] in self?.onPartial?(preview) }
                }
            }
            return String(finalized.characters)
        }

        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finishUtterance() async throws -> String {
        continuation?.finish()
        continuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil

        let text = (try? await resultsTask?.value) ?? ""
        resultsTask = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelUtterance() async {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
    }

    // MARK: - Private

    private var analyzerOptions: SpeechAnalyzer.Options {
        // processLifetime keeps the model resident between utterances, reducing
        // time-to-first-word from roughly one second to under fifty
        // milliseconds.
        SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // .fastResults trades a little accuracy in the volatile hypotheses
            // for getting them sooner. That trade is only ever applied to the
            // live preview; finalised results are unaffected.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }
}
