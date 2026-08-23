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
final class AudioCapture {

    /// Invoked on a real-time audio thread; must not block.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
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
            converter = conv
            self.targetFormat = targetFormat
        }

        if !isTapped {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            isTapped = true
        }

        bufferCount = 0
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        Log.audio.info("input device: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch; engine running=\(self.engine.isRunning, privacy: .public)")
    }

    /// Stops delivering buffers immediately and tears down the graph after
    /// `idleGrace`.
    func stop() {
        onBuffer = nil
        let work = DispatchWorkItem { [weak self] in self?.teardown() }
        shutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleGrace, execute: work)
    }

    func teardown() {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning { engine.stop() }
        converter = nil
        targetFormat = nil
    }

    // MARK: - Private

    private func process(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        if bufferCount == 1 || bufferCount % 100 == 0 {
            Log.audio.info("buffer #\(self.bufferCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
        }
        publishLevel(for: buffer)
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

    private func publishLevel(for buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: frames, by: 8) { sum += channel[i] * channel[i] }
        let rms = (sum / Float(max(1, frames / 8))).squareRoot()
        // Scaled so that quiet speech still produces visible movement.
        let level = min(1, max(0, rms * 8))
        if bufferCount == 1 || bufferCount % 100 == 0 {
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
