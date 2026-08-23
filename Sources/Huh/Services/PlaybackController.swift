import AVFoundation
import Combine
import Foundation

/// Audio playback synchronised to the transcript timeline.
///
/// Transcripts record the location of their source media, so each timeline entry
/// is a seek target. A missing source file disables playback silently rather
/// than raising an error, since deleting the source is an expected outcome.
@MainActor
final class PlaybackController: ObservableObject {

    static let shared = PlaybackController()

    @Published private(set) var transcriptID: UUID?
    @Published private(set) var isPlaying = false
    /// The currently playing segment, published only when it changes.
    ///
    /// Publishing raw playback time invalidated every observing view several
    /// times per second, which degrades scrolling on long timelines. Views
    /// require only the active segment identifier.
    @Published private(set) var activeSegmentID: UUID?

    private var time: TimeInterval = 0
    private var segments: [TranscriptSegment] = []

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: Any?

    private init() {}

    static func isAvailable(for transcript: Transcript) -> Bool {
        guard transcript.source == .file, !transcript.sourcePath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: transcript.sourcePath)
    }

    func play(_ transcript: Transcript, from start: TimeInterval) {
        guard Self.isAvailable(for: transcript) else { return }

        if transcriptID != transcript.id {
            teardown()
            let url = URL(fileURLWithPath: transcript.sourcePath)
            let player = AVPlayer(url: url)
            self.player = player
            transcriptID = transcript.id
            segments = transcript.segments

            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.35, preferredTimescale: 600),
                queue: .main
            ) { [weak self] current in
                Task { @MainActor in self?.tick(CMTimeGetSeconds(current)) }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isPlaying = false }
            }
        }

        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        isPlaying = true
        tick(start)
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        teardown()
    }

    private func tick(_ current: TimeInterval) {
        time = current
        // A linear scan is adequate here: it runs roughly three times per
        // second and does not appear in profiles.
        var found: UUID?
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count ? segments[index + 1].start : segment.start + 5
            if current >= segment.start && current < end { found = segment.id; break }
        }
        if found != activeSegmentID { activeSegmentID = found }
    }

    private func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player?.pause()
        player = nil
        transcriptID = nil
        isPlaying = false
        time = 0
        segments = []
        activeSegmentID = nil
    }
}
