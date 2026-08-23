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

    private let barCount = 28
    private let compactWidth: CGFloat = 310
    private let expandedWidth: CGFloat = 580

    private var isExpanded: Bool { !controller.partialText.isEmpty && controller.confirmation == nil }
    private var isListening: Bool {
        controller.state == .listening || controller.state == .starting
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
        .frame(width: isExpanded ? expandedWidth : compactWidth)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.radiusPanel + 6, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(Theme.base.opacity(0.55)) }
                .overlay { shape.strokeBorder(borderTint, lineWidth: 1) }
                .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
                .shadow(color: Theme.live.opacity(isListening ? 0.16 : 0), radius: 20)
        }
        .animation(Theme.spring, value: isExpanded)
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

    private var borderTint: Color {
        if controller.confirmation != nil { return Theme.live.opacity(0.45) }
        return isListening ? Theme.live.opacity(0.38) : Theme.border
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
