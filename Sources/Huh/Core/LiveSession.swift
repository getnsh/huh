import AVFoundation
import Combine
import Foundation

/// A transcription session that runs in the background for as long as you
/// leave it running: a call, a talk, an interview.
///
/// Distinct from dictation in three ways that matter.
///
///  * It transcribes two streams rather than one, and keeps them apart. Your
///    microphone and the Mac's output go to separate recognisers, so every line
///    knows whether you said it or the room did. Mixing them first would be
///    cheaper by one recogniser and would throw that away, and there is no
///    recovering it afterwards from a summed waveform.
///  * It finishes nowhere. Dictation has a key release; a meeting has an hour
///    of speech that must arrive as it is spoken, which is why the engines
///    report finalised pieces through `onFinalSegment` instead of a transcript
///    at the end.
///  * Nothing is typed anywhere. The result is a transcript in the library,
///    ready to be summarised.
@MainActor
final class LiveSession: ObservableObject {

    static let shared = LiveSession()

    enum Voice: String, Codable {
        /// The microphone.
        case you
        /// Everything the Mac is playing: the other people on the call.
        case room

        var label: String { self == .you ? "You" : "Room" }
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        var voice: Voice
        var text: String
        /// Seconds from the start of the session.
        var at: TimeInterval
    }

    /// Why the session is running, which is also what the panel says.
    enum Trigger: Equatable {
        case manual
        case meeting(String)

        /// What the panel is listening to, while it is listening.
        var label: String {
            switch self {
            case .manual: return "Listening"
            case .meeting(let app): return app
            }
        }

        /// What it was, afterwards. "Listening" in the past tense is a lie
        /// about a panel that has stopped.
        var pastLabel: String {
            switch self {
            case .manual: return "Live session"
            case .meeting(let app): return app
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var trigger: Trigger = .manual
    @Published private(set) var startedAt: Date?
    /// The final length, once the session has ended. The readout ticks while
    /// something is running and freezes when it is not: a counter still
    /// climbing on a stopped session says it is still recording.
    @Published private(set) var finalDuration: TimeInterval?
    @Published private(set) var lines: [Line] = []
    /// The not-yet-settled tail of each stream, shown greyed so that the panel
    /// moves while someone is mid-sentence.
    @Published private(set) var youDraft = ""
    @Published private(set) var roomDraft = ""
    @Published private(set) var youHistory: [Float] = []
    @Published private(set) var roomHistory: [Float] = []
    @Published var statusMessage: String?
    /// Set when a session has been written to the library, so the panel can
    /// offer to open it.
    @Published private(set) var savedTranscript: UUID?

    /// Whether the panel is showing the whole session or collapsed to the
    /// mark. It starts collapsed: a session that runs for an hour should sit
    /// at the edge of the screen as a sign of life, not as a wall of text
    /// nobody asked to read yet.
    @Published var isPanelExpanded = false

    /// Whether the edge panel is on screen. Held here rather than in the
    /// panel controller so that one object decides when the session is worth
    /// showing, and the controller only animates.
    @Published private(set) var isPanelVisible = false

    /// A call is happening and nothing is capturing it. The panel offers.
    @Published private(set) var offer: String?
    /// Offers already declined, so a call is not asked about twice.
    private var declined: Set<String> = []

    private let settings = AppSettings.shared
    private var youCapture: AudioCapture?
    private var roomCapture: AudioCapture?
    private var youEngine: TranscriptionEngine?
    private var roomEngine: TranscriptionEngine?
    private var cancellables = Set<AnyCancellable>()

    /// Roughly one second of waveform at one sample per audio buffer.
    private let historyDepth = 44
    /// Where a long turn is broken into a second line. Someone talking
    /// uninterrupted for five minutes is one turn, and one paragraph of it is
    /// unreadable in a panel this wide.
    private static let lineLimit = 320
    /// Finalised text already counted, so a resumed stream cannot duplicate it.
    private var youSettled = ""
    private var roomSettled = ""

    private init() {}

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Which halves are actually capturing. A machine with no microphone
    /// should show that trace as off rather than as silent.
    @Published private(set) var hearsYou = false
    @Published private(set) var hearsRoom = false

    /// The two streams merged into one trace for the collapsed mark, which
    /// has room for a single voice and should show whichever one is talking.
    var markHistory: [Float] {
        guard !youHistory.isEmpty else { return roomHistory }
        guard !roomHistory.isEmpty else { return youHistory }
        let count = min(youHistory.count, roomHistory.count)
        return (0..<count).map { max(youHistory[youHistory.count - count + $0],
                                     roomHistory[roomHistory.count - count + $0]) }
    }

    /// Which side the mark should be tinted for. Decided on the levels rather
    /// than on the drafts, because it has to move with the voice rather than
    /// trail the recogniser by a second.
    var markVoice: Voice {
        let you = youHistory.suffix(4).max() ?? 0
        let room = roomHistory.suffix(4).max() ?? 0
        return you > room ? .you : .room
    }

    /// Whether anything has been heard yet. Used to decide whether a session
    /// is worth saving.
    var hasContent: Bool { !lines.isEmpty }

    // MARK: - Watching for calls

    func beginWatching() {
        let monitor = MeetingMonitor.shared

        settings.$watchesForMeetings
            .sink { watching in
                if watching { monitor.start() } else { monitor.stop() }
            }
            .store(in: &cancellables)

        // A call appearing is either picked up or offered, never ignored. The
        // offer is per application rather than per call so that leaving and
        // rejoining the same Meet does not ask again.
        monitor.$participants
            .sink { [weak self] participants in
                guard let self else { return }
                guard let first = participants.first else {
                    self.offer = nil
                    return
                }
                let name = first.displayName
                guard !self.isRunning else { return }
                guard self.settings.watchesForMeetings else { return }
                if self.settings.capturesMeetingsAutomatically {
                    self.start(trigger: .meeting(name))
                } else if !self.declined.contains(name) {
                    self.offer = name
                    self.isPanelVisible = true
                }
            }
            .store(in: &cancellables)
    }

    func acceptOffer() {
        guard let offer else { return }
        self.offer = nil
        start(trigger: .meeting(offer))
    }

    func declineOffer() {
        if let offer { declined.insert(offer) }
        offer = nil
        isPanelVisible = false
    }

    /// Closes the panel without ending anything. Only reachable once a session
    /// has finished, since while one is running the same control stops it.
    func dismissPanel() {
        guard !isRunning else { return }
        isPanelVisible = false
        savedTranscript = nil
    }

    // MARK: - Running

    func toggle() {
        if isRunning { stop() } else { start(trigger: .manual) }
    }

    func start(trigger: Trigger) {
        guard !isRunning, !isStopping else { return }
        isRunning = true
        self.trigger = trigger
        startedAt = Date()
        lines = []
        youDraft = ""
        roomDraft = ""
        youSettled = ""
        roomSettled = ""
        youHistory = []
        roomHistory = []
        savedTranscript = nil
        offer = nil
        statusMessage = nil
        isPanelVisible = true
        isPanelExpanded = false
        finalDuration = nil
        Log.app.info("live session started: \(trigger.label, privacy: .private)")

        Task { await open() }
    }

    private func open() async {
        do {
            youEngine = try await makeEngine(for: .you)
            roomEngine = try await makeEngine(for: .room)
        } catch {
            statusMessage = error.localizedDescription
            Log.app.error("live session engines failed: \(error.localizedDescription, privacy: .public)")
            await close(save: false)
            return
        }

        // The room is the stream that can fail, because it is the one behind a
        // permission. When it does, the session continues on the microphone
        // and says so, rather than collapsing: half a conversation is still
        // worth having.
        if let roomEngine {
            do {
                let capture = AudioCapture()
                capture.source = .systemAudio
                capture.idleGrace = 0
                capture.onBuffer = { [weak roomEngine] buffer in roomEngine?.append(buffer) }
                capture.onLevel = { [weak self] value in self?.push(value, to: .room) }
                try await roomEngine.beginUtterance()
                try capture.start(targetFormat: try await roomEngine.preferredFormat())
                roomCapture = capture
                hearsRoom = true
            } catch {
                statusMessage = "Only hearing you. \(error.localizedDescription)"
                Log.audio.error("live session room stream failed: \(error.localizedDescription, privacy: .public)")
                roomCapture = nil
                hearsRoom = false
                await roomEngine.cancelUtterance()
                self.roomEngine = nil
            }
        }

        if let youEngine {
            do {
                let capture = AudioCapture()
                capture.source = .microphone
                capture.idleGrace = 0
                capture.onBuffer = { [weak youEngine] buffer in youEngine?.append(buffer) }
                capture.onLevel = { [weak self] value in self?.push(value, to: .you) }
                try await youEngine.beginUtterance()
                try capture.start(targetFormat: try await youEngine.preferredFormat())
                youCapture = capture
                hearsYou = true
            } catch {
                Log.audio.error("live session microphone failed: \(error.localizedDescription, privacy: .public)")
                statusMessage = "Only hearing your Mac. \(error.localizedDescription)"
                youCapture = nil
                hearsYou = false
                await youEngine.cancelUtterance()
                self.youEngine = nil
            }
        }

        if youEngine == nil, roomEngine == nil {
            statusMessage = "Nothing to listen to."
            await close(save: false)
        }
    }

    private func makeEngine(for voice: Voice) async throws -> TranscriptionEngine {
        let engine = EngineFactory.make(settings.engine, locale: settings.locale)
        engine.contextualStrings = Rules.bias
        engine.onPartial = { [weak self] text in
            self?.draft(text, from: voice)
        }
        engine.onFinalSegment = { [weak self] piece in
            self?.settle(piece, from: voice)
        }
        try await engine.prepare()
        return engine
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        Task { await close(save: true) }
    }

    private func close(save: Bool) async {
        youCapture?.teardown()
        roomCapture?.teardown()
        youCapture = nil
        roomCapture = nil

        let you = youEngine
        let room = roomEngine
        youEngine = nil
        roomEngine = nil
        if save {
            _ = try? await you?.finishUtterance()
            _ = try? await room?.finishUtterance()
        } else {
            await you?.cancelUtterance()
            await room?.cancelUtterance()
        }

        finalDuration = elapsed
        // A session that has just ended has a result to offer, so it opens
        // itself rather than waiting to be clicked.
        isPanelExpanded = true
        if save, hasContent { persist() }

        youDraft = ""
        roomDraft = ""
        hearsYou = false
        hearsRoom = false
        isRunning = false
        isStopping = false
        Log.app.info("live session ended with \(self.lines.count, privacy: .public) lines")

        // A finished session stays on screen long enough to offer the
        // transcript, then leaves on its own. One that heard nothing has
        // nothing to offer and goes immediately.
        if savedTranscript == nil {
            isPanelVisible = false
        } else {
            let saved = savedTranscript
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                guard let self, !self.isRunning, self.savedTranscript == saved else { return }
                self.isPanelVisible = false
            }
        }
    }

    // MARK: - Text arriving

    private func draft(_ text: String, from voice: Voice) {
        // `onPartial` reports everything so far; the settled prefix has
        // already been turned into lines, so only the tail is a draft.
        let settled = voice == .you ? youSettled : roomSettled
        var tail = text
        if text.hasPrefix(settled) { tail = String(text.dropFirst(settled.count)) }
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if voice == .you { youDraft = trimmed } else { roomDraft = trimmed }
    }

    private func settle(_ piece: String, from voice: Voice) {
        let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if voice == .you { youSettled += piece; youDraft = "" } else { roomSettled += piece; roomDraft = "" }

        let corrected = CorrectionEngine.apply(text, corrections: Rules.corrections)
        DictionaryStore.shared.recordHits(corrected.applied)
        let cleaned = TextCleanup.apply(corrected.text, level: settings.cleanupLevel)

        // Consecutive pieces from the same voice join rather than stacking as
        // one line each: a recogniser finalises every few words, and a panel
        // of four-word rows is unreadable. A new line begins when the other
        // voice speaks, which is where a reader expects one.
        if var last = lines.last, last.voice == voice, last.text.count < Self.lineLimit {
            last.text += " " + cleaned.text
            lines[lines.count - 1] = last
        } else {
            lines.append(Line(voice: voice, text: cleaned.text, at: elapsed))
        }
    }

    private func push(_ value: Float, to voice: Voice) {
        if voice == .you {
            youHistory.append(value)
            if youHistory.count > historyDepth { youHistory.removeFirst(youHistory.count - historyDepth) }
        } else {
            roomHistory.append(value)
            if roomHistory.count > historyDepth { roomHistory.removeFirst(roomHistory.count - historyDepth) }
        }
    }

    // MARK: - Saving

    private func persist() {
        let body = lines.map { "\($0.voice.label): \($0.text)" }.joined(separator: "\n\n")
        let segments = lines.map { TranscriptSegment(start: $0.at, text: "\($0.voice.label): \($0.text)") }
        let name: String
        switch trigger {
        case .manual:           name = "Live session"
        case .meeting(let app): name = app
        }

        var transcript = Transcript(
            raw: body,
            text: body,
            engine: settings.engine.displayName,
            duration: elapsed,
            source: .meeting,
            sourceName: name,
            segments: segments
        )
        transcript.date = startedAt ?? Date()
        HistoryStore.shared.add(transcript)
        savedTranscript = transcript.id
        Log.app.info("live session saved as \(transcript.id.uuidString, privacy: .public)")
    }

    func openSaved() {
        guard let savedTranscript else { return }
        UIState.shared.section = .transcripts
        UIState.shared.openTranscript = savedTranscript
        AppWindows.showMain()
        isPanelVisible = false
        self.savedTranscript = nil
    }
}
