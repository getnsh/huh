// huh? — push-to-talk dictation and meeting transcription for macOS
// Copyright (C) 2026 getnsh
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. It is distributed WITHOUT ANY WARRANTY; see the GNU General Public
// License for details. You should have received a copy of the licence with this
// program; if not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

@main
struct HuhApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var ui = UIState.shared

    var body: some Scene {
        // A standard document-style window: Dock icon, standard window
        // commands, resizable.
        WindowGroup(Brand.name) {
            MainWindow()
        }
        .defaultSize(width: 820, height: 560)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(controller: controller, ui: ui) }

        // Provides the standard ⌘, settings scene.
        Settings {
            SettingsView()
        }

        // Secondary surface: status and transport while another application
        // has focus.
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
    }
}

private struct AppCommands: Commands {
    @ObservedObject var controller: DictationController
    @ObservedObject var ui: UIState

    var body: some Commands {
        // The app has no document model, so New Item is removed.
        CommandGroup(replacing: .newItem) { }

        CommandMenu("Dictation") {
            Button(controller.state.isBusy ? "Stop Dictation" : "Start Dictation") {
                controller.toggleFromUI()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Learn From Transcripts") {
                AppWindows.showMain()
                LearningScan.shared.runManually()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Transcribe File…") {
                UIState.shared.section = .transcripts
                AppWindows.showMain()
                FileTranscriptionService.shared.chooseFile()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Transcripts") {
                ui.section = .transcripts
                AppWindows.showMain()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Dictionary") {
                ui.section = .dictionary
                AppWindows.showMain()
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button("Open Dictionary File…") {
                DictionaryStore.shared.revealInFinder()
            }

            Button("Copy Last Transcript") {
                guard !controller.lastTranscript.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
            }
            .disabled(controller.lastTranscript.isEmpty)
        }

        CommandGroup(replacing: .help) {
            Button("\(Brand.name) Logs") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Console.app"))
            }
        }
    }
}

// MARK: - Window helpers

enum AppWindows {
    /// Brings the main window forward, reopening it if it was closed.
    static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { window in
            window.canBecomeMain && !(window is NSPanel)
        }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            // No window exists; SwiftUI reopens the WindowGroup.
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
        }
    }

    static func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The selector was renamed in macOS 14; the previous name is retained
        // as a fallback.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: HUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular activation policy: Dock icon, app menu, standard window
        // behaviour.
        NSApp.setActivationPolicy(.regular)
        // The palette is dark-only; pinning the appearance prevents a light
        // system theme from partially applying to native chrome.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Instantiate stores at launch rather than lazily on first view. The
        // dictionary must exist on disk immediately, since it is documented as
        // editable by hand.
        _ = DictionaryStore.shared
        _ = PeopleStore.shared
        _ = DecisionLedger.shared
        _ = AudioDevices.shared
        _ = HistoryStore.shared
        _ = SearchIndex.shared
        _ = VocabularySuggester.shared
        _ = ModelAvailability.shared
        // Process any analysis backlog left by a previous run.
        LearningScan.shared.scheduleQueue()

        let controller = DictationController.shared
        let hud = HUDController(controller: controller)
        self.hud = hud
        controller.bootstrap(hud: hud)

        // `windowResizability` does not reliably enforce the content minimum,
        // allowing the layout to collapse. AppKit enforces it directly.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
            window.minSize = NSSize(width: 700, height: 480)
            window.setFrameAutosaveName("HuhMainWindow")
            if window.frame.width < 700 || window.frame.height < 480 {
                window.setContentSize(NSSize(width: 860, height: 580))
            }
        }
    }

    /// Reopens the main window when the Dock icon is clicked with no windows
    /// open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindows.showMain() }
        return true
    }

    /// Closing the window does not terminate the application: the push-to-talk
    /// key remains active and the menu bar item reflects that.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
