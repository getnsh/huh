import SwiftUI
import UniformTypeIdentifiers

/// The main window.
///
/// Navigation is a single unified bar that also serves as the title bar,
/// containing the section switcher, search field and primary action, with
/// content beginning immediately below it. A sidebar was rejected: with two
/// destinations and no nested hierarchy it consumed roughly a quarter of the
/// window width without aiding navigation.
struct MainWindow: View {
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.border)

            NoInputBanner()
            ScanResultBanner()
            LaunchAtLoginPrompt()

            Group {
                switch ui.section {
                case .transcripts: TranscriptsView()
                case .dictionary:  DictionaryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(ui.section)
            .transition(
                .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.995))
            )

            RecordBar()
        }
        .background(Theme.base)
        .frame(minWidth: 680, minHeight: 460)
        .preferredColorScheme(.dark)
        // Disables the focus ring and keyboard focus loop. The interface is
        // driven by pointer and global hotkey rather than by form traversal, and
        // text fields retain their insertion point as a focus indicator.
        .focusEffectDisabled()
        .onDrop(of: [.fileURL], isTargeted: $ui.isDropTargeted) { handleDrop($0) }
        .overlay { if ui.isDropTargeted { dropOverlay } }
        .animation(Theme.quick, value: ui.isDropTargeted)
        .sheet(isPresented: $ui.showingEditor) { EntryEditorSheet() }
    }
}

private extension MainWindow {

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                UIState.shared.section = .transcripts
                FileTranscriptionService.shared.start(url: url)
            }
        }
        return true
    }

    var dropOverlay: some View {
        ZStack {
            Theme.base.opacity(0.85)
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.live)
                Text("Drop to transcribe")
                    .font(Theme.heading(15))
                    .foregroundStyle(Theme.textPrimary)
                Text("Audio or video — meeting recordings, voice memos")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Theme.live.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(9)
        )
        .transition(.opacity)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var files = FileTranscriptionService.shared

    var body: some View {
        HStack(spacing: 12) {
            // Reserve space for the window controls: the title bar is hidden,
            // not absent.
            Spacer().frame(width: 70)

            Image(systemName: Brand.idleSymbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            SectionSwitcher()

            Spacer(minLength: 12)

            SearchField(
                placeholder: ui.section == .transcripts ? "Search everything" : "Search dictionary",
                text: ui.section == .transcripts ? $ui.transcriptQuery : $ui.dictionaryQuery
            )
            .frame(width: 190)

            LearnButton()
            primaryAction
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch ui.section {
        case .transcripts:
            Button {
                files.chooseFile()
            } label: {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(files.isRunning)
            .help("Transcribe a recording  ⌘O")

        case .dictionary:
            Button {
                switch ui.dictionaryTab {
                case .terms:       ui.openEditor(.newTerm)
                case .corrections: ui.openEditor(.newCorrection)
                case .people:      ui.openEditor(.newPerson)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help({
                switch ui.dictionaryTab {
                case .terms:       return "Add a word"
                case .corrections: return "Add a correction"
                case .people:      return "Add a person"
                }
            }())
        }
    }
}

/// Runs the analysis pass over all transcripts. Available from either section,
/// since the two halves of the result appear in different places.
private struct LearnButton: View {
    @ObservedObject private var scan = LearningScan.shared
    @ObservedObject private var vocabulary = VocabularySuggester.shared
    @ObservedObject private var suggester = CorrectionSuggester.shared

    private var pending: Int { scan.pendingCount }

    var body: some View {
        Button {
            scan.runManually()
        } label: {
            HStack(spacing: 6) {
                if scan.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                }
                Text(scan.isRunning ? "Reading…" : "Learn")
                if scan.pending > 0 && !scan.isRunning {
                    Text("\(scan.pending) queued")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.warning)
                }
                if pending > 0 && !scan.isRunning {
                    Text("\(pending)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.live))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(SecondaryButtonStyle(tint: pending > 0 ? Theme.live : Theme.textSecondary))
        .disabled(scan.isRunning)
        .help("Scan your transcripts for words and fixes worth teaching it")
        .animation(Theme.spring, value: pending)
        .animation(Theme.quick, value: scan.isRunning)
    }
}

/// Section switcher. The selection indicator translates between positions
/// rather than cutting, which is easier to track visually.
private struct SectionSwitcher: View {
    @ObservedObject private var ui = UIState.shared

    private let segment: CGFloat = 104
    private let height: CGFloat = 28

    private var index: Int {
        UIState.Section.allCases.firstIndex(of: ui.section) ?? 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.hover)
                .frame(width: segment, height: height)
                .offset(x: CGFloat(index) * segment)

            HStack(spacing: 0) {
                ForEach(UIState.Section.allCases) { section in
                    Button {
                        ui.section = section
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 11, weight: .medium))
                            Text(section.title)
                                .font(Theme.medium(12.5))
                        }
                        .foregroundStyle(ui.section == section ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: segment, height: height)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.base))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.borderSoft, lineWidth: 1))
        .animation(Theme.spring, value: ui.section)
    }
}

/// Shown when the machine has no audio input.
///
/// A desktop Mac often has no built-in microphone. Left undetected, this
/// surfaces as an error the instant the push-to-talk key is pressed, which
/// reads as the application being broken rather than as a missing device.
private struct NoInputBanner: View {
    @ObservedObject private var devices = AudioDevices.shared

    var body: some View {
        if let problem = devices.problem {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                Text(problem)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Text("Transcribing a recording still works.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textTertiary)
                Button("Check Again") { devices.refresh() }
                    .buttonStyle(GhostButtonStyle(tint: Theme.warning))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.warning.opacity(0.08))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.spring, value: devices.hasInput)
        }
    }
}

/// Result of the most recent explicit analysis pass.
private struct ScanResultBanner: View {
    @ObservedObject private var scan = LearningScan.shared

    var body: some View {
        if scan.result != nil {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.live)
                Text(scan.result ?? "")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                if scan.canRestoreDismissed {
                    Button("Show Dismissed") { scan.restoreDismissed() }
                        .buttonStyle(GhostButtonStyle(tint: Theme.live))
                }
                Button("Dismiss") { scan.dismissResult() }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.spring, value: scan.result)
            .animation(Theme.quick, value: scan.isRunning)
        }
    }
}

// MARK: - Launch at login

/// Login item prompt, presented once.
private struct LaunchAtLoginPrompt: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launch = LaunchAtLogin.shared

    private var shouldShow: Bool { !settings.hasAskedLaunchAtLogin && !launch.isEnabled }

    var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.live)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start \(Brand.name) when you log in?")
                        .font(Theme.medium(12.5))
                        .foregroundStyle(Theme.textPrimary)
                    Text("The push-to-talk key only works while the app is running.")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                Button("Not Now") { settings.hasAskedLaunchAtLogin = true }
                    .buttonStyle(GhostButtonStyle())

                Button("Start at Login") {
                    launch.setEnabled(true)
                    settings.hasAskedLaunchAtLogin = true
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Record bar

/// Transport bar. Expands, brightens and widens its waveform while the
/// microphone is open, so capture state is legible at a distance.
private struct RecordBar: View {
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var settings = AppSettings.shared

    private var isLive: Bool {
        controller.state == .listening || controller.state == .starting
    }

    private var barCount: Int { isLive ? 44 : 22 }

    var body: some View {
        HStack(spacing: 14) {
            LevelBars(
                history: controller.levelHistory,
                barCount: barCount,
                maxHeight: isLive ? 26 : 16,
                active: isLive
            )
            .frame(width: LevelBars.width(barCount: barCount), height: isLive ? 26 : 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if isLive {
                        Circle()
                            .fill(Theme.live)
                            .frame(width: 6, height: 6)
                            .modifier(Pulse())
                    }
                    Text(statusText)
                        .font(Theme.medium(12.5))
                        .foregroundStyle(isLive ? Theme.live : Theme.textSecondary)
                }
                if !controller.partialText.isEmpty {
                    Text(controller.partialText)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 8)

            if !isLive {
                HStack(spacing: 5) {
                    Text("Hold")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(ModifierKey.named(mask: settings.hotkeyMask).label)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
                }
                .transition(.opacity)

                Credit()
            }

            Button {
                controller.toggleFromUI()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isLive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(isLive ? "Stop" : "Start")
                }
                .frame(minWidth: 46)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: isLive ? 62 : 46)
        .background(isLive ? Theme.raised : Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .animation(Theme.spring, value: isLive)
        .animation(Theme.quick, value: controller.partialText.isEmpty)
    }

    private var statusText: String {
        if !controller.hotkeyArmed { return "Needs Accessibility" }
        switch controller.state {
        case .idle:          return controller.enginePrepared ? "Ready" : "Loading model…"
        case .starting:      return "Starting…"
        case .listening:     return "Listening"
        case .transcribing:  return "Transcribing…"
        case .failed(let m): return m
        }
    }
}

/// Attribution line.
private struct Credit: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("made by getnsh with")
            Text("♥").foregroundStyle(Theme.danger.opacity(0.7))
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.textTertiary.opacity(0.6))
    }
}

/// Pulsing indicator for the recording state, driven by `TimelineView`.
private struct Pulse: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let wave = 0.5 + 0.5 * sin(t * 3.4)
            content
                .opacity(0.55 + 0.45 * wave)
                .scaleEffect(0.9 + 0.2 * wave)
        }
    }
}
