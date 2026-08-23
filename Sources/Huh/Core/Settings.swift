import Foundation
import Combine

enum EngineID: String, CaseIterable, Identifiable, Codable {
    case appleSpeech
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (on-device)"
        case .parakeet: return "Parakeet TDT (Neural Engine)"
        }
    }

    /// Whether this build can actually run the engine.
    ///
    /// A picker must never offer an option that breaks the application. An
    /// engine that is present in the type but not implemented is excluded from
    /// selection and reported separately.
    var isAvailable: Bool { true }

    /// User-facing explanation for an unavailable engine. Never developer
    /// instructions — those belong in the repository, not in Settings.
    var unavailableNote: String? { nil }

    /// Whether selecting this engine causes a one-time model download.
    var requiresModelDownload: Bool { self == .parakeet }

    var note: String? {
        switch self {
        case .appleSpeech:
            return "Models are supplied by macOS. No download, no network."
        case .parakeet:
            return "Downloads about 600 MB from the model registry the first time it is used, then runs entirely offline. Provides word-level timings for speaker attribution."
        }
    }

    static var available: [EngineID] { allCases.filter(\.isAvailable) }
}

/// Which model writes meeting summaries.
///
/// Separate from `EngineID`, which selects a speech recogniser. The two are
/// unrelated choices: transcription accuracy and summary quality are different
/// problems solved by different models, and someone may reasonably want the
/// system recogniser with a better writer, or the reverse.
enum SummaryEngineID: String, CaseIterable, Identifiable, Codable {
    case apple
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple on-device (fast)"
        case .qwen:  return "Qwen3 4B (better, downloads)"
        }
    }

    var note: String {
        switch self {
        case .apple:
            return "Supplied by macOS. No download. Its 4,096-token limit means a long meeting is read in pieces and stitched together, which loses some detail at the seams."
        case .qwen:
            return "Downloads about \(LocalLanguageModel.downloadSize) once, then runs offline like everything else. Reads a whole meeting in one pass rather than in pieces, so the summary is written by something that has seen all of it. Slower, and uses more memory while it runs."
        }
    }

    var requiresDownload: Bool { self == .qwen }
}

enum TriggerMode: String, CaseIterable, Identifiable, Codable {
    case hold          // push-to-talk: transcribe while the key is down
    case toggle        // tap to start, tap to stop

    var id: String { rawValue }
    var displayName: String { self == .hold ? "Hold to talk" : "Tap to toggle" }
}

enum InjectionMode: String, CaseIterable, Identifiable, Codable {
    case auto          // try Accessibility insert, fall back to paste
    case pasteOnly

    var id: String { rawValue }
    var displayName: String { self == .auto ? "Accessibility, then paste" : "Always paste" }
}

/// Persisted user settings. Small enough to keep in UserDefaults for now.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var engine: EngineID {
        didSet { store.set(engine.rawValue, forKey: "engine") }
    }
    @Published var triggerMode: TriggerMode {
        didSet { store.set(triggerMode.rawValue, forKey: "triggerMode") }
    }
    @Published var injectionMode: InjectionMode {
        didSet { store.set(injectionMode.rawValue, forKey: "injectionMode") }
    }
    /// Raw CGEventFlags bit identifying the push-to-talk modifier.
    @Published var hotkeyMask: UInt64 {
        didSet { store.set(String(hotkeyMask), forKey: "hotkeyMask") }
    }
    @Published var localeIdentifier: String {
        didSet { store.set(localeIdentifier, forKey: "localeIdentifier") }
    }
    @Published var playFeedbackSounds: Bool {
        didSet { store.set(playFeedbackSounds, forKey: "playFeedbackSounds") }
    }
    @Published var cleanupLevel: CleanupLevel {
        didSet { store.set(cleanupLevel.rawValue, forKey: "cleanupLevel") }
    }
    /// Which model writes summaries. Defaults to Apple's, so nothing downloads
    /// unless the choice is made deliberately.
    @Published var summaryEngine: SummaryEngineID {
        didSet { store.set(summaryEngine.rawValue, forKey: "summaryEngine") }
    }
    /// Whether the login-item prompt has been shown. Presented once only.
    @Published var hasAskedLaunchAtLogin: Bool {
        didSet { store.set(hasAskedLaunchAtLogin, forKey: "hasAskedLaunchAtLogin") }
    }

    private let store = UserDefaults.standard

    private init() {
        // Self-heal a persisted selection that this build cannot honour, so an
        // engine removed or renamed between versions cannot leave the
        // application permanently unable to transcribe.
        let stored = EngineID(rawValue: store.string(forKey: "engine") ?? "") ?? .appleSpeech
        engine = stored.isAvailable ? stored : .appleSpeech
        triggerMode = TriggerMode(rawValue: store.string(forKey: "triggerMode") ?? "") ?? .hold
        injectionMode = InjectionMode(rawValue: store.string(forKey: "injectionMode") ?? "") ?? .auto
        hotkeyMask = UInt64(store.string(forKey: "hotkeyMask") ?? "") ?? ModifierKey.rightOption.mask
        localeIdentifier = store.string(forKey: "localeIdentifier") ?? Locale.current.identifier
        playFeedbackSounds = store.object(forKey: "playFeedbackSounds") as? Bool ?? true
        cleanupLevel = CleanupLevel(rawValue: store.string(forKey: "cleanupLevel") ?? "") ?? .standard
        summaryEngine = SummaryEngineID(rawValue: store.string(forKey: "summaryEngine") ?? "") ?? .apple
        hasAskedLaunchAtLogin = store.bool(forKey: "hasAskedLaunchAtLogin")
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// A short list rather than the full locale set: the picker exists for
    /// switching between commonly used locales, not for browsing.
    static let commonLocales: [String] = {
        var ids = ["en_US", "en_GB", "en_AU", "en_IN", "en_CA",
                   "fr_FR", "de_DE", "es_ES", "it_IT", "pt_BR",
                   "nl_NL", "ja_JP", "ko_KR", "zh_CN"]
        let current = Locale.current.identifier
        if !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }()
}
