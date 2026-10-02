import AVFoundation
import Foundation

/// One system-audio tap, shared by everything that wants it.
///
/// Two features need what the Mac is playing: holding the key while a video is
/// open, and a meeting running in the background. A tap each would work, and
/// would mean two aggregate devices carrying identical audio, two sets of
/// permission failures to report, and a race over which one tears down last.
/// The hub keeps a single tap, started when the first listener arrives and
/// destroyed when the last one leaves.
///
/// Listeners are invoked on the audio thread, in the order they subscribed.
final class SystemAudioHub: @unchecked Sendable {

    static let shared = SystemAudioHub()

    private let lock = NSLock()
    private let tap = SystemAudioTap()
    private var sinks: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    /// The sinks as a flat array, rebuilt on every change.
    ///
    /// The audio thread must not allocate, and flattening a dictionary's
    /// values allocates. Subscribing and unsubscribing are rare; delivery
    /// happens a hundred times a second, so the cost belongs on the rare side.
    private var fanout: [(AVAudioPCMBuffer) -> Void] = []

    private init() {
        tap.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.lock.lock()
            let listeners = self.fanout
            self.lock.unlock()
            for listener in listeners { listener(buffer) }
        }
    }

    var isRunning: Bool { tap.isRunning }

    /// The format the tap delivers. Nil until the tap has been started once.
    var format: AVAudioFormat? { tap.streamFormat }

    /// Starts the tap if it is not already running and returns a token to
    /// unsubscribe with. Throws the underlying Core Audio failure, which for a
    /// first run is usually the permission not having been granted yet.
    func subscribe(_ sink: @escaping (AVAudioPCMBuffer) -> Void) throws -> UUID {
        let token = UUID()
        lock.lock()
        sinks[token] = sink
        fanout = Array(sinks.values)
        let isFirst = sinks.count == 1
        lock.unlock()

        if isFirst {
            do {
                try tap.start()
            } catch {
                lock.lock()
                sinks.removeValue(forKey: token)
                fanout = Array(sinks.values)
                lock.unlock()
                throw error
            }
        }
        return token
    }

    func unsubscribe(_ token: UUID) {
        lock.lock()
        sinks.removeValue(forKey: token)
        fanout = Array(sinks.values)
        let isEmpty = sinks.isEmpty
        lock.unlock()
        if isEmpty { tap.stop() }
    }
}
