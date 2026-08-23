import AppKit
import CoreGraphics

/// A modifier key usable as a push-to-talk trigger.
///
/// Detection uses the device-dependent modifier bits defined in `IOLLEvent.h`
/// rather than `CGEventFlags`, because only the former distinguish left from
/// right. The right-hand Option key is the default: it rarely collides with
/// application shortcuts.
struct ModifierKey: Identifiable, Hashable {
    let id: String
    let label: String
    let mask: UInt64

    static let rightOption  = ModifierKey(id: "rightOption",  label: "Right ⌥",     mask: 0x000040)
    static let leftOption   = ModifierKey(id: "leftOption",   label: "Left ⌥",      mask: 0x000020)
    static let rightCommand = ModifierKey(id: "rightCommand", label: "Right ⌘",     mask: 0x000010)
    static let rightControl = ModifierKey(id: "rightControl", label: "Right ⌃",     mask: 0x002000)
    static let rightShift   = ModifierKey(id: "rightShift",   label: "Right ⇧",     mask: 0x000004)
    static let fnKey        = ModifierKey(id: "fn",           label: "fn / 🌐",     mask: 0x800000)

    static let all: [ModifierKey] = [.rightOption, .leftOption, .rightCommand, .rightControl, .rightShift, .fnKey]

    static func named(mask: UInt64) -> ModifierKey {
        all.first { $0.mask == mask } ?? .rightOption
    }
}

/// Observes a global `CGEventTap` for press and release of the push-to-talk
/// modifier.
///
/// Two constraints govern the implementation:
///
///  * Accessibility permission is required. Without it `CGEvent.tapCreate`
///    returns nil, which is reported to the interface rather than failing
///    silently.
///  * The tap is `listenOnly`, so events are never consumed and the modifier
///    continues to function normally in other applications. Making the key
///    exclusive would require `.defaultTap` and returning nil from the
///    callback.
final class HotkeyMonitor {

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called when the tap could not be installed (almost always: no Accessibility).
    var onPermissionMissing: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var mask: UInt64

    init(mask: UInt64) {
        self.mask = mask
    }

    func updateMask(_ newMask: UInt64) {
        mask = newMask
        if isDown { isDown = false; onRelease?() }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.accessibilityTrusted else {
            onPermissionMissing?()
            return false
        }

        let events = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(events),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onPermissionMissing?()
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that blocks for too long; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }

        let flags = event.flags.rawValue
        let nowDown = (flags & mask) != 0
        guard nowDown != isDown else { return }
        isDown = nowDown

        DispatchQueue.main.async { [weak self] in
            nowDown ? self?.onPress?() : self?.onRelease?()
        }
    }
}
