import AppKit
import Combine
import Foundation
import ServiceManagement

/// Login item registration via `SMAppService`.
///
/// `SMAppService` is the supported mechanism: it requires no helper script or
/// AppleScript automation, and the registration is revocable by the user from
/// System Settings ▸ General ▸ Login Items.
///
/// Registration may return `.requiresApproval`, indicating that the user must
/// confirm the item themselves. This is a valid state rather than a failure, and
/// the interface surfaces it with a direct link to the relevant settings pane.
@MainActor
final class LaunchAtLogin: ObservableObject {

    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var failure: String?

    private init() { refresh() }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    var explanation: String {
        switch status {
        case .enabled:
            return "\(Brand.name) starts automatically when you log in."
        case .requiresApproval:
            return "macOS needs you to approve this in Login Items."
        case .notFound:
            return "macOS can't find the app bundle — run ./scripts/install.sh."
        default:
            return "The push-to-talk key only works while \(Brand.name) is running."
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("launch at login set to \(enabled, privacy: .public)")
        } catch {
            failure = error.localizedDescription
            Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
