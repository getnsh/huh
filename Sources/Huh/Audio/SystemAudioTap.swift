import Foundation
import CoreAudio
import AVFoundation

/// Captures what the Mac is playing, so a meeting, a call or a video can be
/// transcribed alongside your own voice.
///
/// Built on Core Audio process taps rather than ScreenCaptureKit. Both can do
/// it; ScreenCaptureKit would require Screen Recording permission, which means
/// granting an application that transcribes audio the ability to watch your
/// screen. A tap asks only for audio.
///
/// Verified standalone on this machine before any of it went in the app: the
/// tap is created, the private aggregate device activates, and the format
/// comes back as 48 kHz mono float. The one thing that cannot be proved from a
/// loose binary is the permission, because a command-line tool has no bundle
/// identifier for the system to attribute the request to.
///
/// Playback is left unmuted: you still hear the thing being captured.
final class SystemAudioTap: @unchecked Sendable {

    enum Failure: LocalizedError {
        case tap(OSStatus)
        case aggregate(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tap(let status):
                return status == 1 || status == 560_161_140
                    ? "huh? needs permission to record system audio."
                    : "Could not tap system audio (\(status))."
            case .aggregate(let status): return "Could not build the capture device (\(status))."
            case .ioProc(let status): return "Could not attach to system audio (\(status))."
            case .start(let status):
                return "Could not start capturing system audio (\(status)). Grant huh? permission under Privacy & Security."
            }
        }
    }

    /// Called on the audio thread with float samples at `streamFormat`.
    ///
    /// Synchronised for the same reason `AudioCapture` synchronises its own:
    /// reading a closure reference is a pointer load plus a retain, and racing
    /// that against a write is an over-release on the audio thread rather than
    /// a dropped buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onBuffer }
        set { lock.lock(); _onBuffer = newValue; lock.unlock() }
    }
    private var _onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// The format the tap delivers, known only once it has been created.
    var streamFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return format
    }

    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        // A global tap: everything the machine plays, mixed to mono, which is
        // all speech recognition wants and half the data.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "\(Brand.name) system audio"
        description.isPrivate = true
        description.isMono = true
        description.muteBehavior = CATapMuteBehavior(rawValue: 0) ?? .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw Failure.tap(tapStatus) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let formatStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard formatStatus == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            teardown(); throw Failure.tap(formatStatus)
        }
        lock.lock(); format = avFormat; lock.unlock()

        // A private aggregate device whose only member is the tap. Private so
        // it never appears in the user's sound settings as a stray device.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Brand.name) system audio",
            kAudioAggregateDeviceUIDKey: "\(Brand.bundleID).tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let deviceStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard deviceStatus == noErr else { teardown(); throw Failure.aggregate(deviceStatus) }
        deviceID = device

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.deliver(inInputData)
        }
        guard procStatus == noErr, let proc else { teardown(); throw Failure.ioProc(procStatus) }
        procID = proc

        let startStatus = AudioDeviceStart(deviceID, proc)
        guard startStatus == noErr else { teardown(); throw Failure.start(startStatus) }

        isRunning = true
        Log.audio.info("system audio tap running at \(Int(avFormat.sampleRate), privacy: .public) Hz")
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        Log.audio.info("system audio tap stopped")
    }

    private func teardown() {
        isRunning = false
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        lock.lock(); format = nil; lock.unlock()
    }

    deinit { teardown() }

    // MARK: - The audio thread

    private func deliver(_ data: UnsafePointer<AudioBufferList>) {
        lock.lock()
        let handler = _onBuffer
        let format = self.format
        lock.unlock()
        guard let handler, let format else { return }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = list.first, first.mDataByteSize > 0 else { return }
        let frames = first.mDataByteSize / UInt32(MemoryLayout<Float>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        if let destination = buffer.floatChannelData?[0], let source = first.mData {
            memcpy(destination, source, Int(first.mDataByteSize))
        }
        handler(buffer)
    }
}
