import AppKit
import AVFoundation
import Combine
import SwiftUI

enum DictationState: Equatable {
    case idle
    case starting
    case listening
    case transcribing
    case failed(String)

    var isBusy: Bool {
        self == .starting || self == .listening || self == .transcribing
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The state machine everything else hangs off.
///
///   idle ──press──▶ starting ──▶ listening ──release──▶ transcribing ──▶ idle
///                                    │                                    ▲
///                                    └──────── too-short / error ─────────┘
@MainActor
final class DictationController: ObservableObject {

    static let shared = DictationController()

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var level: Float = 0
    /// Rolling window of input levels, newest last. Held here rather than in
    /// the view so that the overlay remains stateless.
    @Published private(set) var levelHistory: [Float] = []
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var enginePrepared = false
    @Published private(set) var hotkeyArmed = false
    /// True when the machine has no audio input at all. Surfaced up front
    /// rather than as a failure at the moment the key is pressed.
    @Published private(set) var inputMissing = false
    @Published var statusMessage: String?
    /// Set briefly after insertion so the overlay can confirm the destination.
    /// Dictation is performed while another application has focus, where a
    /// silent success is indistinguishable from a failure.
    @Published private(set) var confirmation: String?

    private let settings = AppSettings.shared
    private let audio = AudioCapture()
    private var hotkey: HotkeyMonitor
    private var engine: TranscriptionEngine?
    private var hud: HUDController?

    /// Which engine configuration is currently loaded. Preparing an engine can
    /// mean downloading and loading several hundred megabytes of model, so it
    /// is rebuilt only when the thing that defines it actually changes.
    private var loadedConfiguration: EngineConfiguration?
    private var preparation: Task<Void, Never>?

    private var rearmTimer: Timer?
    private var stopRequested = false
    private var pressedAt: Date?
    private var utteranceStart: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Shorter activations are treated as stray keypresses.
    private let minimumUtterance: TimeInterval = 0.18

    /// Approximately one second of waveform at one sample per audio buffer.
    private let historyDepth = 44

    private init() {
        hotkey = HotkeyMonitor(mask: AppSettings.shared.hotkeyMask)
    }

    // MARK: - Lifecycle

    func bootstrap(hud: HUDController) {
        self.hud = hud

        audio.onLevel = { [weak self] value in
            guard let self else { return }
            self.level = value
            self.levelHistory.append(value)
            if self.levelHistory.count > self.historyDepth {
                self.levelHistory.removeFirst(self.levelHistory.count - self.historyDepth)
            }
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onPermissionMissing = { [weak self] in
            self?.statusMessage = "Accessibility access is required for the push-to-talk key."
        }

        settings.$hotkeyMask
            .dropFirst()
            .sink { [weak self] mask in self?.hotkey.updateMask(mask) }
            .store(in: &cancellables)

        // Both settings define the engine, so they are observed as one value and
        // compared against what is loaded. Observing them separately rebuilt the
        // engine twice for a single change, and rebuilt it at all for a change
        // that left the configuration identical.
        Publishers.CombineLatest(settings.$engine, settings.$localeIdentifier)
            .dropFirst()
            .map { EngineConfiguration(engine: $0, localeIdentifier: $1) }
            .removeDuplicates()
            .sink { [weak self] configuration in self?.rebuildEngine(for: configuration) }
            .store(in: &cancellables)

        AudioDevices.shared.$hasInput
            .sink { [weak self] present in self?.inputMissing = !present }
            .store(in: &cancellables)

        AudioDevices.shared.refresh()
        inputMissing = !AudioDevices.shared.hasInput

        Log.app.info("bootstrap: accessibility=\(Permissions.accessibilityTrusted, privacy: .public) mic=\(Permissions.microphoneAuthorized, privacy: .public) input=\(AudioDevices.shared.hasInput, privacy: .public)")

        Task {
            _ = await Permissions.requestMicrophone()
            Permissions.requestAccessibility()
            armHotkey()
            await prepareEngine()
        }
    }

    /// Starts or stops dictation from the window or menu, independently of the
    /// push-to-talk key.
    func toggleFromUI() {
        if state == .listening || state == .starting { end() } else { begin() }
    }

    func startFromUI() { begin() }
    func stopFromUI() { end() }

    var canStart: Bool { state == .idle || state.isFailed }

    func retryHotkey() {
        statusMessage = nil
        armHotkey()
    }

    /// Accessibility is typically granted after launch, since it requires a
    /// visit to System Settings, by which point the initial tap installation has
    /// already failed. Retrying until it succeeds removes a relaunch step from
    /// onboarding at negligible cost.
    private func armHotkey() {
        if hotkey.start() {
            Log.app.info("hotkey armed")
            hotkeyArmed = true
            rearmTimer?.invalidate()
            rearmTimer = nil
            if statusMessage?.contains("Accessibility") == true { statusMessage = nil }
            return
        }

        hotkeyArmed = false
        guard rearmTimer == nil else { return }
        rearmTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.armHotkey() }
        }
    }

    private func rebuildEngine(for configuration: EngineConfiguration) {
        guard configuration != loadedConfiguration else { return }
        Log.asr.info("engine configuration changed to \(configuration.engine.rawValue, privacy: .public)")
        preparation?.cancel()
        preparation = nil
        engine = nil
        enginePrepared = false
        loadedConfiguration = nil
        Task { await prepareEngine() }
    }

    /// Idempotent and single-flight. Several call sites can ask for a prepared
    /// engine at once — launch, a settings change, and the start of an utterance
    /// — and a second concurrent preparation would re-enter model loading.
    private func prepareEngine() async {
        if let existing = preparation {
            await existing.value
            return
        }
        let task = Task { await performPreparation() }
        preparation = task
        await task.value
        preparation = nil
    }

    private func performPreparation() async {
        let configuration = EngineConfiguration(
            engine: settings.engine,
            localeIdentifier: settings.localeIdentifier
        )
        if enginePrepared, loadedConfiguration == configuration, engine != nil { return }

        let engine = engine ?? EngineFactory.make(settings.engine, locale: settings.locale)
        engine.onPreparationStatus = { [weak self] (status: String) in
            Task { @MainActor in
                self?.statusMessage = status.isEmpty ? nil : status
            }
        }
        engine.onPartial = { [weak self] (text: String) in
            Task { @MainActor in
                Log.asr.debug("partial: \(text.count, privacy: .public) chars")
                self?.partialText = text
            }
        }
        self.engine = engine
        Log.asr.info("preparing engine \(engine.id.rawValue, privacy: .public)")
        do {
            try await engine.prepare()
            enginePrepared = true
            loadedConfiguration = configuration
            statusMessage = nil
            Log.asr.info("engine ready")
        } catch {
            enginePrepared = false
            loadedConfiguration = nil
            statusMessage = error.localizedDescription
            Log.asr.error("engine prepare failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Trigger handling

    private func handlePress() {
        switch settings.triggerMode {
        case .hold:
            pressedAt = Date()
            begin()
        case .toggle:
            if state == .listening { end() } else { pressedAt = Date(); begin() }
        }
    }

    private func handleRelease() {
        guard settings.triggerMode == .hold else { return }
        if let pressedAt, Date().timeIntervalSince(pressedAt) < minimumUtterance {
            cancel()
            return
        }
        end()
    }

    // MARK: - Machine

    private func begin() {
        guard !state.isBusy else { return }

        // Checked here as well as observed, because a device can be unplugged
        // between the last notification and this keypress.
        AudioDevices.shared.refresh()
        if let problem = AudioDevices.shared.problem {
            statusMessage = problem
            state = .failed(problem)
            hud?.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if case .failed = self?.state { self?.state = .idle }
            }
            return
        }

        guard let engine else {
            statusMessage = "No transcription engine loaded."
            return
        }
        state = .starting
        partialText = ""
        confirmation = nil
        levelHistory.removeAll(keepingCapacity: true)
        stopRequested = false
        utteranceStart = Date()

        // Mechanism one: supply the dictionary to the engine as bias.
        engine.contextualStrings = Rules.bias
        hud?.show()
        chime(.start)

        Task { [engine] in
            do {
                if !enginePrepared { await prepareEngine() }
                guard enginePrepared else { fail("Engine unavailable."); return }

                let format = try await engine.preferredFormat()
                Log.audio.info("engine format: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
                try await engine.beginUtterance()
                audio.onBuffer = { [weak engine] buffer in engine?.append(buffer) }
                try audio.start(targetFormat: format)
                Log.audio.info("capture started")

                if stopRequested {
                    stopRequested = false
                    state = .listening
                    end()
                } else {
                    state = .listening
                }
            } catch {
                Log.app.error("begin failed: \(error.localizedDescription, privacy: .public)")
                fail(error.localizedDescription)
            }
        }
    }

    private func end() {
        if state == .starting { stopRequested = true; return }
        guard state == .listening else { return }

        state = .transcribing
        audio.stop()

        Task {
            guard let engine else { fail("Engine went away."); return }
            do {
                let raw = try await engine.finishUtterance()
                Log.asr.info("final transcript: \(raw.count, privacy: .public) chars")

                if raw.isEmpty {
                    statusMessage = "Nothing heard."
                } else {
                    // Mechanism two: the deterministic path. Bias is advisory;
                    // this is what enforces the dictionary.
                    let result = CorrectionEngine.apply(raw, corrections: Rules.corrections)
                    DictionaryStore.shared.recordHits(result.applied)

                    if !result.applied.isEmpty {
                        Log.asr.info("corrections fired: \(result.applied.count, privacy: .public)")
                    }

                    // Corrections are applied first, against the recogniser's
                    // literal output; cleanup then operates on the result.
                    let cleaned = TextCleanup.apply(result.text, level: settings.cleanupLevel)

                    lastTranscript = cleaned.text
                    let outcome = TextInjector.insert(cleaned.text, mode: settings.injectionMode)
                    confirm(outcome.label)

                    HistoryStore.shared.add(Transcript(
                        raw: raw,
                        text: cleaned.text,
                        corrections: result.applied,
                        engine: settings.engine.displayName,
                        duration: utteranceStart.map { Date().timeIntervalSince($0) } ?? 0,
                        cleanupRemoved: cleaned.removed
                    ))
                }
                partialText = ""
                level = 0
                levelHistory.removeAll(keepingCapacity: true)
                state = .idle
                if confirmation == nil { hud?.hide() }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Holds the overlay visible long enough to be read, then dismisses it.
    private func confirm(_ message: String) {
        confirmation = message
        chime(.stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.confirmation == message else { return }
            self.confirmation = nil
            if !self.state.isBusy { self.hud?.hide() }
        }
    }

    private func cancel() {
        guard state.isBusy else { return }
        audio.stop()
        let engine = self.engine
        Task { await engine?.cancelUtterance() }
        partialText = ""
        level = 0
        levelHistory.removeAll(keepingCapacity: true)
        state = .idle
        hud?.hide()
    }

    private func fail(_ message: String) {
        statusMessage = message
        state = .failed(message)
        audio.stop()
        hud?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if case .failed = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Chrome

    var menuBarSymbol: String {
        switch state {
        case .idle:         return Brand.idleSymbol
        case .starting,
             .listening:    return Brand.listeningSymbol
        case .transcribing: return Brand.workingSymbol
        case .failed:       return Brand.errorSymbol
        }
    }

    private enum Chime { case start, stop }

    private func chime(_ kind: Chime) {
        guard settings.playFeedbackSounds else { return }
        NSSound(named: kind == .start ? "Tink" : "Pop")?.play()
    }
}
