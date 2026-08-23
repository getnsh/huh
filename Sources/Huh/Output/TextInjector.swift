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

    /// The mechanism used, reported to the interface.
    enum Outcome {
        case inserted     // Accessibility API, straight into the focused field
        case pasted       // clipboard + ⌘V, clipboard restored afterwards
        case copied       // no insertion target; left on the pasteboard

        var label: String {
            switch self {
            case .inserted: return "Inserted at cursor"
            case .pasted:   return "Pasted at cursor"
            case .copied:   return "Copied to clipboard"
            }
        }
    }

    @discardableResult
    static func insert(_ text: String, mode: InjectionMode) -> Outcome {
        guard !text.isEmpty else { return .copied }

        if mode == .auto, insertViaAccessibility(text) {
            Log.inject.info("inserted via accessibility")
            return .inserted
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
        return .pasted
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
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              // swiftlint:disable:next force_cast
              CFGetTypeID(focused!) == AXUIElementGetTypeID()
        else { return false }

        let element = focused as! AXUIElement

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

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Allow the receiving application time to read the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let snapshot, !snapshot.isEmpty else { return }
            pasteboard.clearContents()
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
        // Prevent the synthesised ⌘V from being observed by local handlers.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
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
