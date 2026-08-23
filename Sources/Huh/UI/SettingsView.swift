import SwiftUI

/// The settings scene. Scoped to the options that materially change behaviour;
/// everything else uses a sensible default.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var launch = LaunchAtLogin.shared
    @ObservedObject private var devices = AudioDevices.shared
    @ObservedObject private var localModel = LocalLanguageModel.shared

    var body: some View {
        // Scrolling, not a taller window.
        //
        // The content was previously pinned to a fixed 520pt height, so every
        // group added since -- Microphone among them -- was clipped off the
        // bottom with no indication anything was missing. A window tall enough
        // for all of it would not fit a laptop display.
        ScrollView {
            content
        }
        .frame(width: 520, height: 560)
        .background(Theme.base)
        .scrollBounceBehavior(.basedOnSize)
        .focusEffectDisabled()
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Push-to-talk") {
                row("Key") {
                    Picker("", selection: $settings.hotkeyMask) {
                        ForEach(ModifierKey.all) { key in
                            Text(key.label).tag(key.mask)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                row("Behaviour") {
                    Picker("", selection: $settings.triggerMode) {
                        ForEach(TriggerMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                note("The key still works normally in every other app — \(Brand.name) only listens for it, it never swallows it.")
            }

            group("Microphone") {
                HStack(spacing: 7) {
                    Circle()
                        .fill(devices.hasInput ? Theme.live : Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(devices.hasInput
                         ? "Input: \(devices.inputName)"
                         : "No audio input device is connected.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Check Again") { devices.refresh() }
                        .buttonStyle(GhostButtonStyle())
                }
                if !devices.hasInput {
                    note("Many desktop Macs have no built-in microphone. Transcribing an existing recording works regardless.")
                }
            }

            group("Model") {
                row("Engine") {
                    Picker("", selection: $settings.engine) {
                        ForEach(EngineID.available) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
                if let note = settings.engine.note {
                    note_(note)
                }
                row("Language") {
                    Picker("", selection: $settings.localeIdentifier) {
                        ForEach(AppSettings.commonLocales, id: \.self) { id in
                            Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
                HStack(spacing: 7) {
                    Circle()
                        .fill(controller.enginePrepared ? Theme.live : Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(controller.enginePrepared ? "Model loaded and warm" : (controller.statusMessage ?? "Loading…"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            group("Summaries") {
                row("Written by") {
                    Picker("", selection: $settings.summaryEngine) {
                        ForEach(SummaryEngineID.allCases) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
                note(settings.summaryEngine.note)

                if settings.summaryEngine == .qwen {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(localModel.isReady ? Theme.live : Theme.warning)
                            .frame(width: 6, height: 6)
                        Text(localModel.statusText)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if localModel.isReady {
                            Button("Unload") { localModel.unload() }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }

            group("On-device intelligence") {
                IntelligenceNotice(compact: true)
                note("Finding names and unfamiliar words uses Apple's on-device model, as do summaries unless you chose otherwise above. Dictation, transcription, the dictionary, cleanup, search and export do not, and are unaffected by this setting.")
            }

            group("Cleanup") {
                row("Tidy transcripts") {
                    Picker("", selection: $settings.cleanupLevel) {
                        ForEach(CleanupLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                note(settings.cleanupLevel.detail)
            }

            group("Startup") {
                HStack {
                    Text("Start at login")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { launch.isEnabled },
                        set: { launch.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                HStack(spacing: 7) {
                    Circle()
                        .fill(launch.isEnabled ? Theme.live : (launch.needsApproval ? Theme.warning : Theme.textTertiary))
                        .frame(width: 6, height: 6)
                    Text(launch.failure ?? launch.explanation)
                        .font(Theme.body(11.5))
                        .foregroundStyle(launch.failure != nil ? Theme.danger : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if launch.needsApproval {
                    Button("Open Login Items…") { launch.openLoginItemsSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            group("Insertion") {
                row("Insert with") {
                    Picker("", selection: $settings.injectionMode) {
                        ForEach(InjectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
                Toggle("Feedback sounds", isOn: $settings.playFeedbackSounds)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                note("Electron apps (Slack, VS Code, Discord) generally need the paste path. Native apps take the Accessibility path cleanly.")
            }

        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.medium(11))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.7)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            content()
        }
    }

    private func note_(_ text: String) -> some View { note(text) }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(11.5))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
