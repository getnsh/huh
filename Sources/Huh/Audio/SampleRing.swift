import Foundation

/// A fixed-capacity ring of float samples, written on one real-time thread and
/// read on another.
///
/// Mixing two live streams means the writer -- the system-audio tap -- and the
/// reader -- the microphone tap -- run on different threads driven by
/// different clocks. Neither may block and neither may allocate. A ring of a
/// known size satisfies both: a write is a pair of copies, and a read that
/// finds nothing returns what it found rather than waiting for the rest.
///
/// Drift is handled by the capacity itself rather than by resampling. The two
/// clocks sit in the same device and the aggregate compensates for what little
/// they diverge, but over an hour the writer can still creep ahead. When it
/// laps the ring it overwrites the oldest samples, which costs a few
/// milliseconds of the far end at the moment it happens and puts the streams
/// back in step permanently. The alternative, an unbounded queue, trades those
/// milliseconds for a delay that grows all meeting.
final class SampleRing: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Float]
    /// Where the next sample is written.
    private var writeIndex = 0
    /// How many unread samples the ring holds.
    private var available = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1024, capacity))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return available
    }

    /// Appends samples, discarding the oldest if the ring is full.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let capacity = storage.count
        // A single write larger than the whole ring can only keep its newest
        // part. Writing the older part first and immediately overwriting it
        // would be the same result for more work.
        let n = min(count, capacity)
        let src = source.advanced(by: count - n)
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let head = min(n, capacity - writeIndex)
            base.advanced(by: writeIndex).update(from: src, count: head)
            if n > head {
                base.update(from: src.advanced(by: head), count: n - head)
            }
        }
        writeIndex = (writeIndex + n) % capacity
        available = min(capacity, available + n)
        lock.unlock()
    }

    /// Copies up to `count` samples out and returns how many were written.
    /// A short read is normal: it means the far end is briefly silent or has
    /// not caught up, and the caller treats the remainder as silence.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        let capacity = storage.count
        let n = min(count, available)
        if n > 0 {
            let start = (writeIndex - available + capacity) % capacity
            storage.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let head = min(n, capacity - start)
                destination.update(from: base.advanced(by: start), count: head)
                if n > head {
                    destination.advanced(by: head).update(from: base, count: n - head)
                }
            }
            available -= n
        }
        lock.unlock()
        return n
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        available = 0
        lock.unlock()
    }
}
