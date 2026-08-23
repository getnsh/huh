import AppKit
import Combine
import Foundation
import FoundationModels

/// Availability of the on-device language model, as a single source of truth.
///
/// Two features depend on `SystemLanguageModel`: summarisation and correction
/// proposals. Neither is required for the application to function, so an
/// unavailable model must degrade rather than fail. Every other capability —
/// dictation, transcription, the dictionary, cleanup, search, export, playback,
/// and vocabulary detection via `NSSpellChecker` and `NLTagger` — is
/// independent of it.
///
/// Availability can change while the application is running, since the user may
/// enable Apple Intelligence in System Settings and return, so state is
/// re-evaluated whenever the application becomes active.
@MainActor
final class ModelAvailability: ObservableObject {

    static let shared = ModelAvailability()

    enum State: Equatable {
        /// The model is loaded and usable.
        case ready
        /// Supported hardware, but Apple Intelligence has not been turned on.
        case notEnabled
        /// Turned on; macOS is still downloading the model.
        case downloading
        /// The hardware cannot run the model.
        case notEligible
        /// Reported unavailable for a reason this build does not recognise.
        case other(String)
    }

    @Published private(set) var state: State = .notEnabled

    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var isReady: Bool { state == .ready }

    func refresh() {
        let resolved: State
        switch SystemLanguageModel.default.availability {
        case .available:
            resolved = .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: resolved = .notEnabled
            case .modelNotReady:               resolved = .downloading
            case .deviceNotEligible:           resolved = .notEligible
            @unknown default:                  resolved = .other("The on-device model is unavailable.")
            }
        @unknown default:
            resolved = .other("The on-device model is unavailable.")
        }

        if resolved != state {
            state = resolved
            Log.app.info("language model availability: \(String(describing: resolved), privacy: .public)")
        }
    }

    // MARK: - Presentation

    var headline: String {
        switch state {
        case .ready:        return "On-device model ready"
        case .notEnabled:   return "Apple Intelligence is turned off"
        case .downloading:  return "Apple Intelligence is still downloading"
        case .notEligible:  return "This Mac can't run the on-device model"
        case .other:        return "On-device model unavailable"
        }
    }

    var detail: String {
        switch state {
        case .ready:
            return "Summaries and correction suggestions run locally on this Mac."
        case .notEnabled:
            return "Turn on Apple Intelligence in System Settings to enable summaries and correction suggestions. Everything else works without it."
        case .downloading:
            return "macOS is downloading the model. This finishes in the background; try again shortly."
        case .notEligible:
            return "Summaries and correction suggestions need Apple silicon with Apple Intelligence support. Every other feature works normally."
        case .other(let message):
            return message
        }
    }

    /// Whether the user can act on this state, and what the action is called.
    var actionTitle: String? {
        switch state {
        case .notEnabled:  return "Open Apple Intelligence Settings…"
        case .downloading: return "Check Again"
        default:           return nil
        }
    }

    func performAction() {
        switch state {
        case .notEnabled: openSettings()
        case .downloading: refresh()
        default: break
        }
    }

    func openSettings() {
        // The Apple Intelligence & Siri pane, identified by its Settings
        // extension bundle identifier.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
