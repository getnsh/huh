import AVFoundation

/// Captures audio and delivers it to a transcription engine in that engine's
/// required format.
///
/// Three design decisions:
///
///  * The audio graph starts on key-down and stops shortly after key-up, so the
///    system microphone indicator reflects actual capture. This costs roughly
///    40–60 ms of start-up latency; `idleGrace` keeps the graph alive between
///    consecutive utterances so that cost is paid once.
///  * Format conversion is performed here rather than in each engine, so an
///    engine declares `preferredFormat()` and receives exactly that.
///  * What is being captured is a property of this object rather than a
///    separate class per source. The microphone and the system tap arrive on
///    different threads at different rates, but everything downstream of the
///    conversion is identical, and duplicating it would mean maintaining two
///    copies of the threading argument below.
final class AudioCapture: @unchecked Sendable {

    /// Where the audio comes from.
    enum Source {
        /// The default input device.
        case microphone
        /// Whatever the Mac is playing.
        case systemAudio
        /// Both, summed into one stream. Used for dictation, where the engine
        /// takes a single input and the point is to transcribe a video and a
        /// remark about it as one sentence.
        case mixed
    }

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

    /// The level of the system audio alone, when mixing. The interface shows
    /// the two sources as separate traces, so a single summed level would make
    /// a silent microphone look live whenever a video was playing.
    var onSystemLevel: ((Float) -> Void)?

    /// Which sources to capture. Set before `start`; changing it while running
    /// has no effect until the next start.
    var source: Source = .microphone

    /// Reported when the system tap could not be started, which in practice
    /// means the permission has not been granted. Dictation continues on the
    /// microphone alone rather than failing outright.
    var onSystemAudioUnavailable: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isTapped = false
    private var shutdownWork: DispatchWorkItem?
    private var bufferCount = 0

    // System audio.
    private var hubToken: UUID?
    private var systemConverter: AVAudioConverter?
    private var systemBufferCount = 0
    /// Half a second of 48 kHz mono. Sized as the drift budget, not as a
    /// queue: see `SampleRing`.
    private let systemRing = SampleRing(capacity: 24_000)

    /// How long the audio graph stays running after an utterance ends.
    var idleGrace: TimeInterval = 4.0

    var isRunning: Bool {
        switch source {
        case .microphone, .mixed: return engine.isRunning
        case .systemAudio:        return hubToken != nil
        }
    }

    func start(targetFormat: AVAudioFormat) throws {
        shutdownWork?.cancel()
        shutdownWork = nil

        if source == .systemAudio {
            lock.lock()
            self.targetFormat = targetFormat
            bufferCount = 0
            lock.unlock()
            try startSystemAudio(targetFormat: targetFormat, mixing: false)
            return
        }

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

        // The microphone is the stream that must work. A tap that cannot start
        // is reported and skipped, never allowed to take dictation down with
        // it.
        if source == .mixed, hubToken == nil {
            do {
                try startSystemAudio(targetFormat: targetFormat, mixing: true)
            } catch {
                Log.audio.error("system audio unavailable: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { [weak self] in self?.onSystemAudioUnavailable?(error) }
            }
        }
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
        stopSystemAudio()
        lock.lock()
        converter = nil
        targetFormat = nil
        lock.unlock()
    }

    // MARK: - System audio

    private func startSystemAudio(targetFormat: AVAudioFormat, mixing: Bool) throws {
        let hub = SystemAudioHub.shared
        systemRing.reset()
        systemBufferCount = 0

        // The tap's format is only known once it exists, and it exists only
        // once someone subscribes -- so the converter is built on the first
        // buffer rather than here.
        lock.lock(); systemConverter = nil; lock.unlock()

        hubToken = try hub.subscribe { [weak self] buffer in
            self?.ingestSystem(buffer, mixing: mixing)
        }
        Log.audio.info("system audio subscribed (mixing=\(mixing, privacy: .public))")
    }

    private func stopSystemAudio() {
        if let hubToken {
            SystemAudioHub.shared.unsubscribe(hubToken)
            self.hubToken = nil
        }
        systemRing.reset()
        lock.lock(); systemConverter = nil; lock.unlock()
    }

    /// The system tap's thread. Converts to the engine's format, then either
    /// parks the samples for the microphone thread to mix in, or delivers them
    /// as the stream in their own right.
    private func ingestSystem(_ buffer: AVAudioPCMBuffer, mixing: Bool) {
        lock.lock()
        let target = targetFormat
        var converter = systemConverter
        systemBufferCount += 1
        let count = systemBufferCount
        let sink = _onBuffer
        lock.unlock()
        guard let target else { return }

        if converter == nil {
            guard let built = AVAudioConverter(from: buffer.format, to: target) else { return }
            lock.lock(); systemConverter = built; lock.unlock()
            converter = built
            Log.audio.info("system audio: \(buffer.format.sampleRate, privacy: .public) Hz, \(buffer.format.channelCount, privacy: .public) ch -> \(target.sampleRate, privacy: .public) Hz")
        }
        // Measured on the tap's own buffer, not on the converted one.
        //
        // An engine's preferred format is whatever that engine wants, and
        // several of them want integer samples -- for which `floatChannelData`
        // is nil and the level silently never arrives. The microphone path has
        // always measured its raw input for this reason; so does this one now.
        publishLevel(for: buffer, count: count, system: mixing)

        guard let converter, let out = convert(buffer, with: converter, to: target) else { return }

        if mixing {
            guard let samples = out.floatChannelData?[0] else { return }
            systemRing.write(samples, count: Int(out.frameLength))
        } else {
            sink?(out)
        }
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
        publishLevel(for: buffer, count: count, system: false)
        guard let converter, let targetFormat, let onBuffer else { return }
        guard let out = convert(buffer, with: converter, to: targetFormat) else { return }

        if source == .mixed { mixSystemAudio(into: out) }
        onBuffer(out)
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         with converter: AVAudioConverter,
                         to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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

        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Sums the parked system samples into the microphone buffer in place.
    ///
    /// Summed, not averaged. Halving both would make a quiet room quieter for
    /// no benefit; a recogniser cares about the shape of speech, and the only
    /// thing that genuinely destroys it is clipping, so the sum is clamped
    /// instead. A short read is silence, which is the correct answer when the
    /// Mac is not playing anything.
    private func mixSystemAudio(into out: AVAudioPCMBuffer) {
        let frames = Int(out.frameLength)
        guard frames > 0, let channels = out.floatChannelData else { return }

        var scratch = [Float](repeating: 0, count: frames)
        let read = scratch.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return systemRing.read(into: base, count: frames)
        }
        guard read > 0 else { return }

        for channel in 0..<Int(out.format.channelCount) {
            let destination = channels[channel]
            for frame in 0..<read {
                destination[frame] = max(-1, min(1, destination[frame] + scratch[frame]))
            }
        }
    }

    private func publishLevel(for buffer: AVAudioPCMBuffer, count: Int, system: Bool) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: frames, by: 8) { sum += channel[i] * channel[i] }
        let rms = (sum / Float(max(1, frames / 8))).squareRoot()
        // Scaled so that quiet speech still produces visible movement.
        let level = min(1, max(0, rms * 8))
        if !system, count == 1 || count % 100 == 0 {
            Log.audio.info("rms=\(rms, privacy: .public) level=\(level, privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if system { self.onSystemLevel?(level) } else { self.onLevel?(level) }
        }
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
