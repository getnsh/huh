import AVFoundation
import Foundation
import FluidAudio

/// Parakeet TDT running on the Apple Neural Engine, via FluidAudio's
/// Swift/CoreML port.
///
/// Chosen over the system recogniser when speaker attribution matters: Apple's
/// speech framework returns text without any indication of who spoke, and
/// FluidAudio supplies word-level timings that can be attributed to speakers.
///
/// The models are not bundled. They are fetched from the model registry on
/// first use and cached in Application Support, which is the one operation in
/// this application that requires network access. It happens once, only if this
/// engine is selected, and progress is reported throughout.
///
/// Ordering note: `StreamingUnifiedAsrManager` is an actor, while
/// `append(_:)` is called synchronously from the real-time audio thread.
/// Dispatching each buffer as its own `Task` would not preserve arrival order.
/// Buffers are therefore queued under a lock and drained sequentially by a
/// single consumer task.
final class ParakeetEngine: TranscriptionEngine {

    let id: EngineID = .parakeet
    var onPartial: ((String) -> Void)?
    var onPreparationStatus: ((String) -> Void)?
    var contextualStrings: [String] = []

    private let locale: Locale
    private var manager: StreamingUnifiedAsrManager?

    /// Buffers awaiting delivery to the actor, in arrival order.
    private let queueLock = NSLock()
    private var queue: [AVAudioPCMBuffer] = []
    private var drainTask: Task<Void, Never>?

    init(locale: Locale) {
        self.locale = locale
    }

    // MARK: - Preparation

    func prepare() async throws {
        if manager != nil { return }

        let manager = StreamingUnifiedAsrManager()
        await manager.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor in self?.onPartial?(text) }
        }

        await report("Preparing Parakeet…")
        do {
            try await manager.loadModels(
                to: nil,
                configuration: nil,
                progressHandler: { [weak self] progress in
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    Task { @MainActor in
                        self?.onPreparationStatus?("Downloading Parakeet models… \(percent)%")
                    }
                }
            )
        } catch {
            await report("")
            Log.asr.error("parakeet model load failed: \(error.localizedDescription, privacy: .public)")
            throw TranscriptionError.modelDownloadFailed(error.localizedDescription)
        }

        self.manager = manager
        await report("")
        Log.asr.info("parakeet models loaded")
    }

    func preferredFormat() async throws -> AVAudioFormat {
        // The manager resamples internally, so this is the format the capture
        // stage should produce rather than a hard requirement.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.notPrepared
        }
        return format
    }

    // MARK: - Utterance

    func beginUtterance() async throws {
        guard let manager else { throw TranscriptionError.notPrepared }
        try await manager.reset()

        queueLock.lock()
        queue.removeAll(keepingCapacity: true)
        queueLock.unlock()

        drainTask?.cancel()
        drainTask = Task { [weak self] in
            await self?.drain(manager)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queueLock.lock()
        queue.append(buffer)
        queueLock.unlock()
    }

    func finishUtterance() async throws -> String {
        guard let manager else { throw TranscriptionError.notPrepared }

        drainTask?.cancel()
        drainTask = nil

        // Deliver whatever is still queued before flushing, so no trailing
        // audio is discarded.
        for buffer in takeQueued() {
            try? await manager.appendAudio(buffer)
        }

        let text = try await manager.finish()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelUtterance() async {
        drainTask?.cancel()
        drainTask = nil
        queueLock.lock()
        queue.removeAll(keepingCapacity: true)
        queueLock.unlock()
        try? await manager?.reset()
    }

    // MARK: - Private

    /// Feeds queued buffers to the actor in order and asks it to decode what it
    /// can. Runs until the utterance ends.
    private func drain(_ manager: StreamingUnifiedAsrManager) async {
        while !Task.isCancelled {
            let buffers = takeQueued()
            if buffers.isEmpty {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            for buffer in buffers {
                try? await manager.appendAudio(buffer)
            }
            try? await manager.processBufferedAudio()
        }
    }

    private func takeQueued() -> [AVAudioPCMBuffer] {
        queueLock.lock()
        defer { queueLock.unlock() }
        let buffers = queue
        queue.removeAll(keepingCapacity: true)
        return buffers
    }

    @MainActor
    private func report(_ status: String) {
        onPreparationStatus?(status)
    }
}
