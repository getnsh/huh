import AppKit
import ApplicationServices

/// Delivers transcribed text to the frontmost application.
///
/// Two strategies are attempted in order:
///
///  1. **Accessibility insertion.** Resolves the focused element through the
///     system-wide `AXUIElement` and sets its selected text. This avoids the
///     pasteboard and synthetic keystrokes entirely and preserves undo
///     behaviour. It works in native AppKit and SwiftUI text views, and fails in
///     Chromium-based applications — sometimes reporting success, which is why
///     the element is validated first.
///
///  2. **Pasteboard and ⌘V.** Universally supported. The pasteboard is
///     snapshotted, replaced, pasted, and restored. The restore delay is
///     required: Chromium reads the pasteboard asynchronously and will paste
///     stale content if it is restored too early.
enum TextInjector {

    /// The mechanism used and where the text landed, reported to the interface.
    ///
    /// The destination is carried because dictation happens while another
    /// application has focus. "Inserted at cursor" is true but uninformative:
    /// the one thing worth confirming is *which* window received it, since a
    /// mis-aimed insertion looks identical to a successful one from here.
    enum Outcome {
        /// Accessibility API, straight into the focused field.
        case inserted(app: String?)
        /// Clipboard and ⌘V, clipboard restored afterwards.
        case pasted(app: String?)
        /// No insertion target; left on the pasteboard.
        case copied

        var label: String {
            switch self {
            case .inserted(let app):
                return app.map { "Inserted into \($0)" } ?? "Inserted at cursor"
            case .pasted(let app):
                return app.map { "Pasted into \($0)" } ?? "Pasted at cursor"
            case .copied:
                return "Copied to clipboard"
            }
        }
    }

    @discardableResult
    static func insert(_ text: String, mode: InjectionMode) -> Outcome {
        guard !text.isEmpty else { return .copied }

        // Resolved before anything is written. Insertion can move focus, and
        // the paste path posts ⌘V to whatever is frontmost at that instant, so
        // asking afterwards can name the wrong application.
        let destination = destinationApp()

        if mode == .auto, insertViaAccessibility(text) {
            Log.inject.info("inserted via accessibility")
            return .inserted(app: destination)
        }

        // With no editable target, synthesising ⌘V would discard the text;
        // leave it on the pasteboard and report that instead.
        guard hasEditableFocus() || mode == .pasteOnly else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Log.inject.info("no editable focus, left on clipboard")
            return .copied
        }

        pasteViaClipboard(text)
        Log.inject.info("pasted via clipboard")
        return .pasted(app: destination)
    }

    // MARK: - Destination

    /// The application about to receive the text.
    ///
    /// The owner of the focused accessibility element is preferred over the
    /// frontmost application, because they can differ: a floating panel or an
    /// input method may be frontmost while the caret belongs to the window
    /// behind it. The element's owning process is where the text actually goes.
    private static func destinationApp() -> String? {
        if Permissions.accessibilityTrusted {
            let system = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let value = focused,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                // swiftlint:disable:next force_cast
                let element = value as! AXUIElement
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success,
                   let owner = NSRunningApplication(processIdentifier: pid),
                   let name = usableName(owner) {
                    return name
                }
            }
        }
        return NSWorkspace.shared.frontmostApplication.flatMap(usableName)
    }

    /// Nil for anything that is not a meaningful destination, which the label
    /// then falls back from rather than naming something confusing.
    ///
    /// The overlay is a non-activating panel and does not take focus, but
    /// dictation started from the main window legitimately leaves this
    /// application frontmost — and "Inserted into huh?" would be nonsense.
    private static func usableName(_ app: NSRunningApplication) -> String? {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        guard let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// Whether an editable insertion target exists. Used only to choose between
    /// pasting and leaving the text on the pasteboard.
    private static func hasEditableFocus() -> Bool {
        guard Permissions.accessibilityTrusted else { return true }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        // Elements exposing a settable value or selected text accept a paste.
        // Web views report neither reliably, hence the permissive default.
        var settable: DarwinBoolean = false
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue { return true }
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if settable.boolValue { return true }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let name = role as? String ?? ""
        return name != kAXStaticTextRole as String && !name.isEmpty
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard Permissions.accessibilityTrusted else { return false }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        // `focused` is filled in across a process boundary by whichever
        // application has focus. A buggy one can report success and leave it
        // empty, so it is unwrapped safely rather than forced.
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }

        let element = value as! AXUIElement

        // Restrict to elements that declare themselves editable text.
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard editableRoles.contains(role) else { return false }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    // MARK: - Clipboard

    /// Type used by clipboard managers to mean "do not record or sync this".
    /// Marking the transcript with it keeps a dictated sentence out of
    /// clipboard history and away from Universal Clipboard, which would
    /// otherwise carry it to the user's other devices.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealed)

        // Recorded after writing, so the restore can tell "nothing has touched
        // the pasteboard since" from "the user copied something in the
        // meantime".
        let mark = pasteboard.changeCount

        postCommandV()

        // Allow the receiving application time to read the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            // Never clobber a copy the user made while the paste was in
            // flight -- 450 ms is long enough for a deliberate Cmd-C.
            guard pasteboard.changeCount == mark else { return }

            pasteboard.clearContents()

            // An empty snapshot means the pasteboard was empty beforehand, and
            // clearing is the correct restore. Returning early instead would
            // leave the transcribed speech on the system pasteboard
            // indefinitely, readable by every process on the machine.
            guard !snapshot.isEmpty else { return }

            let items = snapshot.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Local keyboard events must stay permitted.
        //
        // This filter governs which *hardware* events survive the suppression
        // interval that follows a posted event, not whether the synthetic event
        // is observable. Omitting keyboard here silently swallowed whatever the
        // user typed in the quarter-second after each paste.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKeyCode: CGKeyCode = 9 // ANSI 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
