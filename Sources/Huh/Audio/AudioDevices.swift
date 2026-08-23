import AVFoundation
import AppKit
import Combine
import Foundation

/// Tracks whether the machine has an audio input at all.
///
/// A desktop Mac frequently has no built-in microphone. Without this, the
/// absence surfaces as a failure at the moment the push-to-talk key is pressed
/// — the worst possible time, and phrased as though the application had broken.
/// Detecting it up front lets the interface say so while the user is still
/// looking at the interface.
///
/// Discovery is re-run when a device is connected or disconnected, and again
/// when the application is activated, which covers the case of a headset paired
/// while another application had focus.
@MainActor
final class AudioDevices: ObservableObject {

    static let shared = AudioDevices()

    @Published private(set) var hasInput = false
    /// Localised name of the input that would be used, for display.
    @Published private(set) var inputName = ""

    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()

        let center = NotificationCenter.default
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected,
                     NSNotification.Name.AVCaptureDeviceWasDisconnected,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in AudioDevices.shared.refresh() }
            })
        }
    }

    func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = session.devices
        let preferred = AVCaptureDevice.default(for: .audio) ?? devices.first

        let found = preferred != nil
        if found != hasInput {
            Log.audio.info("audio input available: \(found, privacy: .public)")
        }
        hasInput = found
        inputName = preferred?.localizedName ?? ""
    }

    /// Message shown wherever the absence needs explaining. Nil when an input
    /// exists, so call sites can bind directly to it.
    var problem: String? {
        hasInput ? nil : "No microphone is connected. Plug in or pair an input device to dictate."
    }
}
