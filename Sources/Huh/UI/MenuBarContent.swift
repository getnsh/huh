import SwiftUI

/// Menu bar surface. Provides status and transport while another application
/// has focus; all configuration lives in the main window.
struct MenuBarContent: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var devices = AudioDevices.shared

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

    private var statusLine: String {
        switch controller.state {
        case .idle:
            if let problem = devices.problem {
                Divider()
                Text(problem)
                Button("Check Again") { devices.refresh() }
            }

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
