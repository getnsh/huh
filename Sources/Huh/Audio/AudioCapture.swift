import AVFoundation

/// Captures microphone audio from the default input and delivers it to the
/// active transcription engine in that engine's required format.
///
/// Two design decisions:
///
///  * The audio graph starts on key-down and stops shortly after key-up, so the
///    system microphone indicator reflects actual capture. This costs roughly
///    40–60 ms of start-up latency; `idleGrace` keeps the graph alive between
///    consecutive utterances so that cost is paid once.
///  * Format conversion is performed here rather than in each engine, so an
///    engine declares `preferredFormat()` and receives exactly that.
final class AudioCapture: @unchecked Sendable {

    /// Guards everything the render thread and the main thread both touch.
    ///
    /// The tap callback runs on CoreAudio's real-time thread. `start` and
    /// `stop` run on the main actor. `idleGrace` deliberately leaves the tap
    /// installed between utterances, so those two threads overlap by design,
    /// every single time the key is released -- `stop()` releases the closure
    /// while buffers are still arriving to call it.
    ///
    /// Reading a Swift closure or class reference is a pointer load plus a
    /// retain, and neither is atomic. Racing it against a write is not a
    /// dropped buffer, it is an over-release: a use-after-free on the audio
    /// thread. This is the same lock `ParakeetEngine` uses around its queue,
    /// for the same reason.
    ///
    /// It is held only around field access, never across `convert` and never
    /// while calling out, so the real-time thread cannot block on work.
    private let lock = NSLock()

    /// Invoked on a real-time audio thread; must not block.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onBuffer }
        set { lock.lock(); _onBuffer = newValue; lock.unlock() }
    }
    private var _onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Normalised RMS level (0...1), delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isTapped = false
    private var shutdownWork: DispatchWorkItem?
    private var bufferCount = 0

    /// How long the audio graph stays running after an utterance ends.
    var idleGrace: TimeInterval = 4.0

    var isRunning: Bool { engine.isRunning }

    func start(targetFormat: AVAudioFormat) throws {
        shutdownWork?.cancel()
        shutdownWork = nil

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        if self.targetFormat != targetFormat || converter == nil {
            guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioCaptureError.unsupportedConversion(from: inputFormat, to: targetFormat)
            }
            lock.lock()
            converter = conv
            self.targetFormat = targetFormat
            lock.unlock()
        }

        if !isTapped {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            isTapped = true
        }

        lock.lock(); bufferCount = 0; lock.unlock()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        Log.audio.info("input device: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch; engine running=\(self.engine.isRunning, privacy: .public)")
    }

    /// Stops delivering buffers immediately and tears down the graph after
    /// `idleGrace`.
    func stop() {
        onBuffer = nil   // synchronised; see `lock`
        let work = DispatchWorkItem { [weak self] in self?.teardown() }
        shutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleGrace, execute: work)
    }

    func teardown() {
        // Order matters. `removeTap` does not wait for a callback already
        // running, and `stop()` on the engine is what actually joins it -- so
        // the converter must not be released until both have happened, or the
        // render thread can be inside `convert` on an object being freed.
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning { engine.stop() }
        lock.lock()
        converter = nil
        targetFormat = nil
        lock.unlock()
    }

    // MARK: - Private

    private func process(_ buffer: AVAudioPCMBuffer) {
        // One acquisition, strong references taken out. Everything below runs
        // against those copies, so a `stop()` landing mid-conversion cannot
        // pull the converter out from under it -- the objects stay alive until
        // this call returns.
        lock.lock()
        bufferCount += 1
        let count = bufferCount
        let converter = self.converter
        let targetFormat = self.targetFormat
        let onBuffer = self._onBuffer
        lock.unlock()

        if count == 1 || count % 100 == 0 {
            Log.audio.info("buffer #\(count, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
        }
        publishLevel(for: buffer, count: count)
        guard let converter, let targetFormat, let onBuffer else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0 else { return }
        onBuffer(out)
    }

    private func publishLevel(for buffer: AVAudioPCMBuffer, count: Int) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: frames, by: 8) { sum += channel[i] * channel[i] }
        let rms = (sum / Float(max(1, frames / 8))).squareRoot()
        // Scaled so that quiet speech still produces visible movement.
        let level = min(1, max(0, rms * 8))
        if count == 1 || count % 100 == 0 {
            Log.audio.info("rms=\(rms, privacy: .public) level=\(level, privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case unsupportedConversion(from: AVAudioFormat, to: AVAudioFormat)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device is available."
        case .unsupportedConversion(let from, let to):
            return "Can't convert microphone audio (\(Int(from.sampleRate)) Hz) to the engine's format (\(Int(to.sampleRate)) Hz)."
        }
    }
}
