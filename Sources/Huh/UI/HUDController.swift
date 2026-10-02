import AppKit
import SwiftUI

/// Floating status overlay shown during dictation, above the frontmost
/// application.
///
/// The overlay must never take focus, since the target application has to remain
/// frontmost for text insertion to have a destination. It is therefore a
/// `.nonactivatingPanel` `NSPanel` with `becomesKeyOnlyIfNeeded`, not a window.
///
/// The panel itself is a fixed, oversized, transparent canvas anchored to the
/// bottom centre of the screen. All resizing occurs in SwiftUI within that
/// canvas rather than by animating the window frame, which avoids a window
/// server round trip per frame and prevents shadow artefacts.
@MainActor
final class HUDController {

    private var panel: NSPanel?
    private let controller: DictationController
    private let canvasSize = NSSize(width: 760, height: 340)

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // SwiftUI draws its own, shaped to the pill
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: HUDView().environmentObject(controller))
        host.frame = NSRect(origin: .zero, size: canvasSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: visible.midX - canvasSize.width / 2,
                y: visible.minY + 36,
                width: canvasSize.width,
                height: canvasSize.height
            ),
            display: false
        )
    }
}

private struct HUDView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 28
    private let compactWidth: CGFloat = 310
    private let mixedWidth: CGFloat = 388
    private let expandedWidth: CGFloat = 580

    private var isExpanded: Bool { !controller.partialText.isEmpty && controller.confirmation == nil }
    private var isListening: Bool {
        controller.state == .listening || controller.state == .starting
    }
    /// Two sources means two traces, which needs the room to put them in.
    private var isMixed: Bool { controller.isHearingMac && controller.confirmation == nil }

    private var width: CGFloat {
        if isExpanded { return expandedWidth }
        return isMixed ? mixedWidth : compactWidth
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    private var pill: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 14 : 0) {
            header

            if isExpanded {
                Text(controller.partialText)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isExpanded ? 18 : 14)
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.radiusPanel + 6, style: .continuous)
            shape
                .fill(Theme.surface)
                .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        // The press itself is the one moment the overlay is certainly being
        // looked at, so it gets a mark of its own: a ring leaving the pill,
        // and the pill taking the press. Both are one-shot and keyed on the
        // press count rather than on the state, which also changes for
        // reasons that are not a press.
        .background { if !reduceMotion { PressBloom().id(controller.pressCount) } }
        .modifier(PressPop(trigger: controller.pressCount, enabled: !reduceMotion))
        .animation(Theme.spring, value: isExpanded)
        .animation(Theme.spring, value: isMixed)
        .animation(Theme.quick, value: isListening)
        .animation(Theme.spring, value: controller.confirmation)
    }

    @ViewBuilder
    private var header: some View {
        if let confirmation = controller.confirmation {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.live)
                Text(confirmation)
                    .font(Theme.medium(13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if isMixed {
            mixedHeader
        } else {
            liveHeader
        }
    }

    private var liveHeader: some View {
        HStack(spacing: 14) {
            LevelBars(
                history: controller.levelHistory,
                barCount: barCount,
                maxHeight: 24,
                active: isListening
            )
            .frame(width: LevelBars.width(barCount: barCount), height: 26)

            Text(caption)
                .font(Theme.medium(12.5))
                .foregroundStyle(isListening ? Theme.live : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

            if controller.state == .transcribing {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Both sources, stacked and labelled. Which one is carrying the sentence
    /// matters while it is being spoken: a trace that is flat tells you the
    /// video is paused or the microphone is muted, and that is worth knowing
    /// before the transcript arrives rather than after.
    private var mixedHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(caption.isEmpty ? "Listening" : caption)
                    .font(Theme.medium(12.5))
                    .foregroundStyle(isListening ? Theme.live : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if controller.state == .transcribing {
                    ProgressView().controlSize(.small)
                }
            }
            trace("You", controller.levelHistory, Theme.live)
            trace("Mac", controller.systemHistory, Theme.liveSoft)
        }
        .transition(.opacity)
    }

    private func trace(_ label: String, _ history: [Float], _ tint: Color) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(Theme.medium(9.5))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .frame(width: 26, alignment: .leading)
            VoiceTrace(history: history, active: isListening, tint: tint)
                .frame(height: 22)
        }
    }

    private var caption: String {
        switch controller.state {
        case .starting:            return "Starting…"
        case .listening:           return isExpanded ? "" : "Listening"
        case .transcribing:        return "Transcribing…"
        case .failed(let message): return message
        case .idle:                return Brand.tagline
        }
    }
}

/// A ring leaving the pill once, on the press.
///
/// Recreated rather than reset: giving it the press count as its identity
/// means SwiftUI builds a new one per press, and a view that animates on
/// appear needs no state machine to run again.
private struct PressBloom: View {
    @State private var out = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusPanel + 6, style: .continuous)
            .strokeBorder(Theme.live.opacity(0.6), lineWidth: 1.5)
            .scaleEffect(out ? 1.16 : 0.97)
            .opacity(out ? 0 : 0.85)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.62)) { out = true }
            }
    }
}

/// The pill giving a little under the press and springing back.
private struct PressPop: ViewModifier {
    let trigger: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(0.955, duration: 0.09, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.36, spring: .bouncy)
                }
            }
        } else {
            content
        }
    }
}
