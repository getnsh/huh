import Foundation
import CoreAudio
import Combine

/// Notices when a call starts, without watching your screen or your browser.
///
/// Core Audio already keeps a list of every process doing audio, and will say
/// which of them currently has the microphone open. A call is exactly that:
/// some other application listening. That one fact catches Google Meet and
/// anything else in a browser tab, Slack huddles, Zoom, Teams, FaceTime and
/// Discord, with no per-application integration to write and none to maintain
/// when any of them ships a new version.
///
/// Nothing here needs a permission. The process list is readable by anyone,
/// carries no audio, and never leaves the machine. Checked on this Mac: the
/// list comes back fully populated with bundle identifiers, and reports no
/// microphone in use when none is.
@MainActor
final class MeetingMonitor: ObservableObject {

    struct Participant: Equatable, Identifiable {
        let bundleID: String
        let pid: pid_t
        var id: String { bundleID + String(pid) }

        /// A name worth showing someone, derived from the bundle identifier
        /// rather than looked up, so this stays cheap and offline.
        var displayName: String {
            if let known = Self.known[bundleID] { return known }
            for (fragment, name) in Self.fragments where bundleID.contains(fragment) {
                return name
            }
            return bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
        }

        private static let known: [String: String] = [
            "com.tinyspeck.slackmacgap": "Slack",
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams2": "Teams",
            "com.microsoft.teams": "Teams",
            "com.apple.FaceTime": "FaceTime",
            "com.hnc.Discord": "Discord",
            "com.cisco.webexmeetingsapp": "Webex",
            "com.google.Chrome": "Chrome",
            "com.apple.Safari": "Safari",
            "company.thebrowser.Browser": "Arc",
            "com.brave.Browser": "Brave",
        ]
        private static let fragments: [(String, String)] = [
            ("slack", "Slack"), ("zoom", "Zoom"), ("teams", "Teams"),
            ("webex", "Webex"), ("discord", "Discord"), ("chrome", "Chrome"),
            ("firefox", "Firefox"), ("WebKit", "Safari"),
        ]
    }

    static let shared = MeetingMonitor()

    /// Someone other than us has the microphone open.
    @Published private(set) var isCallActive = false
    /// Which applications, newest first. Usually one.
    @Published private(set) var participants: [Participant] = []
    /// When the current call was first seen, for the elapsed readout.
    @Published private(set) var startedAt: Date?

    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        guard timer == nil else { return }
        poll()
        // Polling rather than a property listener: the process list changes
        // for many reasons that are not a call starting, and half a second is
        // far below the threshold where anyone notices a call being spotted
        // late. It costs a few property reads.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Reading the list

    private func poll() {
        let found = listeners()
        let active = !found.isEmpty
        if found != participants { participants = found }
        if active != isCallActive {
            isCallActive = active
            startedAt = active ? Date() : nil
            // Which conferencing applications someone uses, and when, is a
            // record of their day. The fact of a call is public in the log;
            // the names of the applications are not.
            Log.audio.info("call \(active ? "started" : "ended", privacy: .public)\(active ? ": \(found.map(\.displayName).joined(separator: ", "))" : "", privacy: .private)")
        }
    }

    private func listeners() -> [Participant] {
        processObjects().compactMap { object in
            guard flag(object, kAudioProcessPropertyIsRunningInput) else { return nil }
            let pid = pid(of: object)
            guard pid != ownPID, pid > 0 else { return nil }
            guard let bundle = string(object, kAudioProcessPropertyBundleID), !bundle.isEmpty
            else { return nil }
            // The system's own audio plumbing holds input open constantly and
            // is not a meeting.
            guard !Self.systemNoise.contains(where: { bundle.hasPrefix($0) }) else { return nil }
            return Participant(bundleID: bundle, pid: pid)
        }
    }

    private static let systemNoise = [
        "com.apple.audiomxd", "com.apple.CoreSpeech", "com.apple.assistantd",
        "com.apple.Siri", "com.apple.voicebankingd", "com.apple.accessibility",
        "com.apple.universalaccessd", "com.apple.cmio", "com.apple.controlcenter",
        "com.apple.systemsoundserverd", "com.apple.TelephonyUtilities",
    ]

    // MARK: - Core Audio plumbing

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func pid(of object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
