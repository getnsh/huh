import SwiftUI

/// Menu bar surface. Provides status and transport while another application
/// has focus; all configuration lives in the main window.
struct MenuBarContent: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var live: LiveSession
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var devices = AudioDevices.shared
    @ObservedObject var meetings = MeetingMonitor.shared

    var body: some View {
        Group {
            Text("\(Brand.name) — \(statusLine)")

            if let problem = devices.problem {
                Divider()
                Text(problem)
                Button("Check Again") { devices.refresh() }
            }

            if !controller.hotkeyArmed {
                Divider()
                Text("Push-to-talk key is inactive without Accessibility access.")
                Button("Open Accessibility Settings…") { Permissions.openAccessibilitySettings() }
                Button("Recheck Now") { controller.retryHotkey() }
            }

            Divider()

            Button(controller.state.isBusy ? "Stop Dictation" : "Start Dictation") {
                controller.toggleFromUI()
            }

            Button(live.isRunning ? "Stop Listening" : listenTitle) {
                live.toggle()
            }
            .disabled(live.isStopping)

            if !controller.lastTranscript.isEmpty {
                Button("Copy Last Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
                }
            }

            Divider()

            Button("Open \(Brand.name)") { AppWindows.showMain() }
            Button("Settings…") { AppWindows.showSettings() }

            Divider()

            Button("Quit \(Brand.name)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// Named after the call when there is one, so the menu says what it is
    /// about to start listening to rather than leaving it to be guessed.
    private var listenTitle: String {
        if let app = meetings.participants.first?.displayName {
            return "Listen to the \(app) Call"
        }
        return "Listen to This Meeting"
    }

    private var statusLine: String {
        switch controller.state {
        case .idle:
            if live.isRunning { return "in a session" }
            if !devices.hasInput { return "no microphone" }
            if !controller.hotkeyArmed { return "needs Accessibility" }
            return controller.enginePrepared
                ? "hold \(ModifierKey.named(mask: settings.hotkeyMask).label)"
                : "loading model…"
        case .starting, .listening: return "listening"
        case .transcribing:         return "transcribing"
        case .failed:               return "error"
        }
    }
}
