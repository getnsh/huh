import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
        /// A password field had focus, or another application had engaged
        /// secure input. Nothing was written anywhere.
        case refusedSecure

        var label: String {
            switch self {
            case .inserted(let app):
                return app.map { "Inserted into \($0)" } ?? "Inserted at cursor"
            case .pasted(let app):
                return app.map { "Pasted into \($0)" } ?? "Pasted at cursor"
            case .copied:
                return "Copied to clipboard"
            case .refusedSecure:
                return "Not inserted - password field"
            }
        }
    }

    @discardableResult
    static func insert(_ text: String, mode: InjectionMode) -> Outcome {
        guard !text.isEmpty else { return .copied }

        // Checked before anything is written, including the pasteboard.
        // Falling back to the clipboard here would be worse than doing
        // nothing: it would put the spoken text somewhere every process on
        // the machine can read it, in the one situation where the user most
        // obviously did not intend that.
        guard !targetIsSecure() else {
            Log.inject.info("insertion refused: secure input")
            return .refusedSecure
        }

        // Resolved before anything is written. Insertion can move focus, and
        // the paste path posts ⌘V to whatever is frontmost at that instant, so
        // asking afterwards can name the wrong application.
        let destination = destinationApp()

        if mode == .auto, insertViaAccessibility(text) {
            Log.inject.info("inserted via accessibility")
            return .inserted(app: destination)
        }
        if mode == .auto {
            Log.inject.info("accessibility insertion declined, trying the clipboard")
        }

        // Only refuse when the target is known not to accept text. "Cannot
        // tell" must paste: a wasted ⌘V into something unwritable does
        // nothing and the clipboard is restored either way, whereas refusing
        // when there was a perfectly good text field is a visible failure.
        let focus = editableFocus()
        guard focus != .notEditable || mode == .pasteOnly else {
            // Deliberately not restored -- the user has to be able to paste
            // it themselves -- but it is marked the same way the paste path
            // marks it, so it is not recorded by clipboard history and is
            // not carried to the user's other devices.
            leaveOnClipboard(text)
            Log.inject.info("focus not editable, left on clipboard")
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

    /// What is known about the insertion target.
    ///
    /// Three states, not two, because "the accessibility query failed" and
    /// "this element does not take text" call for opposite responses. The
    /// former was previously collapsed into the latter, so an accessibility
    /// call that failed for any reason silently downgraded every dictation to
    /// leaving the text on the clipboard.
    ///
    /// That failure is easy to reach: `AXIsProcessTrusted()` reports the
    /// permission as granted while the individual calls are refused, which is
    /// what happens after a rebuild changes the code signature the grant was
    /// recorded against.
    private enum Focus { case editable, notEditable, unknown }

    private static func editableFocus() -> Focus {
        guard Permissions.accessibilityTrusted else { return .unknown }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Log.inject.info("focus query unavailable (AXError \(status.rawValue, privacy: .public)); assuming a target")
            return .unknown
        }

        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement

        // Elements exposing a settable value or selected text accept a paste.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue { return .editable }
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if settable.boolValue { return .editable }

        // Web views report neither reliably, hence the permissive default:
        // anything that is not explicitly static text is treated as a target.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let name = role as? String ?? ""
        if name.isEmpty {
            Log.inject.info("focused element reports no role; assuming a target")
            return .unknown
        }
        if name == kAXStaticTextRole as String {
            Log.inject.info("focused element is static text")
            return .notEditable
        }
        return .editable
    }

    // MARK: - Secure input

    /// The focused element, or nil when it cannot be resolved.
    private static func focusedElement() -> AXUIElement? {
        guard Permissions.accessibilityTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    /// True when dictated text must not be delivered at all.
    ///
    /// Two separate conditions, either of which is disqualifying:
    ///
    ///  1. **A password field has focus.** An `NSSecureTextField` reports
    ///     `kAXTextFieldRole` exactly like any other text field; the only
    ///     thing that distinguishes it is its subrole, so the role checks
    ///     elsewhere in this file cannot see it.
    ///
    ///  2. **Secure event input is engaged** by any application. While it is,
    ///     the window server discards synthetic keystrokes -- so a paste
    ///     would type nothing and leave the transcript sitting on the
    ///     pasteboard, which is the worst of both outcomes.
    private static func targetIsSecure() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let element = focusedElement() else { return false }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
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

        // Re-checked on the element actually resolved here. Focus can move
        // between the guard in `insert` and this call, and a password field
        // is indistinguishable from a text field by role alone.
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard (subroleValue as? String) != (kAXSecureTextFieldSubrole as String) else { return false }

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

    /// Type used by clipboard managers to mean "do not record this".
    ///
    /// It is a community convention, honoured by third-party clipboard
    /// managers. It is *not* consulted by macOS, so it does nothing about
    /// Universal Clipboard on its own -- that is what `.currentHostOnly`
    /// below is for. Both are needed: one keeps the transcript out of
    /// clipboard history, the other keeps it off the user's other devices.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Writes the transcript to the pasteboard as privately as the system
    /// allows: marked for clipboard managers, and confined to this machine
    /// so Handoff does not carry a dictated sentence to the user's iPhone.
    @discardableResult
    private static func writeConcealed(_ text: String, to pasteboard: NSPasteboard) -> Int {
        let change = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        return change
    }

    /// The fallback when there is nowhere to insert: leave the text where the
    /// user can paste it, and nowhere else.
    private static func leaveOnClipboard(_ text: String) {
        writeConcealed(text, to: .general)
    }

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        writeConcealed(text, to: pasteboard)

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
