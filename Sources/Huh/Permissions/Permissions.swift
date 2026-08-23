import AVFoundation
import ApplicationServices
import AppKit

/// The three TCC gates this app lives or dies by.
enum Permissions {

    // MARK: Microphone

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        if microphoneAuthorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility
    // Needed twice over: CGEventTap can't observe the global hotkey without it,
    // and AXUIElement text insertion is meaningless without it.

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
