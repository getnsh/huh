import AVFoundation

/// Abstraction over speech recognition backends.
///
/// Everything upstream of this protocol — hotkey handling, capture, overlay,
/// insertion — is engine-agnostic; everything downstream is engine-specific.
///
/// Lifecycle: `prepare()` once at launch, then
/// `beginUtterance()` → `append(_:)` × N → `finishUtterance()`.
protocol TranscriptionEngine: AnyObject {
    var id: EngineID { get }

    /// Volatile, not-yet-final text. Delivered on the main queue.
    var onPartial: ((String) -> Void)? { get set }

    /// Progress during `prepare()`, delivered on the main queue.
    ///
    /// First run on a new machine may require a model download of substantial
    /// size. Without this the application is indistinguishable from hung.
    var onPreparationStatus: ((String) -> Void)? { get set }

    /// Terms to bias the recogniser toward; the first of the dictionary's two
    /// mechanisms. Set before `beginUtterance()`. Engines without a biasing
    /// facility ignore this, and the correction pass remains authoritative
    /// either way.
    ///
    /// The list must stay short: long context lists cause these models to drift
    /// and emit spurious text on near-silent audio.
    var contextualStrings: [String] { get set }

    /// Downloads and loads models. Must be idempotent.
    func prepare() async throws

    /// The audio format this engine wants buffers in.
    func preferredFormat() async throws -> AVAudioFormat

    func beginUtterance() async throws

    /// Invoked on the audio thread; must not block.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Flushes and returns the final transcript.
    func finishUtterance() async throws -> String

    func cancelUtterance() async
}

enum TranscriptionError: LocalizedError {
    case engineUnavailable(String)
    case unsupportedLocale(String)
    case notPrepared
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let why):   return why
        case .unsupportedLocale(let id):    return "\(id) isn't supported by this engine."
        case .notPrepared:                  return "The transcription engine wasn't prepared."
        case .modelDownloadFailed(let why): return "Model download failed: \(why)"
        }
    }
}

/// Everything that determines which engine is loaded and how.
///
/// Compared as a whole so that a settings change which leaves the engine
/// unchanged does not tear one down and load it again — an operation that, for
/// a downloaded model, is measured in seconds and hundreds of megabytes.
struct EngineConfiguration: Equatable {
    var engine: EngineID
    var localeIdentifier: String
}

enum EngineFactory {
    static func make(_ id: EngineID, locale: Locale) -> TranscriptionEngine {
        switch id {
        case .appleSpeech: return AppleSpeechEngine(locale: locale)
        case .parakeet:    return ParakeetEngine(locale: locale)
        }
    }
}
