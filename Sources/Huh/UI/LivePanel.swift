import AppKit
import SwiftUI

/// The panel that sits at the edge of the screen while a session runs.
///
/// Same constraints as the dictation overlay and for the same reason: it must
/// never take focus, because the thing being transcribed is in another
/// application and that application has to stay frontmost. Unlike the overlay
/// it is interactive -- there is a stop button on it -- so it takes mouse
/// events while still declining to become key.
@MainActor
final class LivePanelController {

    private var panel: NSPanel?
    private let session: LiveSession
    private var width: CGFloat = 388
    /// The window is sized to its contents rather than given a fixed canvas.
    ///
    /// The overlay can afford an oversized transparent canvas because it
    /// ignores the mouse. This one has buttons on it, so it does not -- and a
    /// 620-point window with 300 points of nothing in it would be an invisible
    /// region down the side of the screen that swallows clicks meant for
    /// whatever is behind it.
    private var height: CGFloat = 240

    /// The top-left corner, in screen coordinates.
    ///
    /// Anchored by its top-left rather than by the window origin AppKit uses,
    /// because the panel changes height whenever it opens or closes and a
    /// bottom-left anchor would make it grow downward out of wherever it was
    /// put. The corner nearest the thing being pointed at is the one that
    /// should stay still.
    private var anchor: CGPoint?
    private var dragOrigin: CGPoint?
    private var dragPointerOrigin: CGPoint?
    private var dragMonitor: Any?

    init(session: LiveSession) {
        self.session = session
    }

    // MARK: - Where it sits

    private func currentAnchor() -> CGPoint {
        if let anchor { return anchor }
        if let saved = AppSettings.shared.panelAnchor {
            anchor = saved
            return saved
        }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let fresh = CGPoint(x: visible.maxX - width - 18, y: visible.maxY - 14)
        anchor = fresh
        return fresh
    }

    /// The window frame for the current anchor and size, kept on a screen.
    ///
    /// Clamped rather than obeyed exactly: a panel dragged to a corner and
    /// then expanded has to open inward, and a display that has been
    /// unplugged since must not leave it somewhere unreachable.
    private func targetFrame() -> NSRect {
        let corner = currentAnchor()
        var frame = NSRect(x: corner.x, y: corner.y - height, width: width, height: height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: corner.x, y: corner.y - 1)) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), max(visible.minX + 8, visible.maxX - width - 8))
            frame.origin.y = min(max(frame.minY, visible.minY + 8), max(visible.minY + 8, visible.maxY - height - 8))
        }
        return frame
    }

    // MARK: - Dragging

    /// Moves the panel with the pointer.
    ///
    /// Driven by the pointer's position on screen rather than by the drag
    /// gesture's own translation, which cannot work here: that translation is
    /// measured against the window, and the window is the thing being moved.
    /// Every frame shifts the reference the next frame is measured from, so
    /// the panel lags, drifts and fights the cursor. A screen coordinate has
    /// no such feedback -- the pointer is where it is whatever the window
    /// underneath it does.
    private func drag(_ phase: PanelDrag) {
        switch phase {
        case .began:
            dragOrigin = currentAnchor()
            dragPointerOrigin = NSEvent.mouseLocation
            // The gesture alone is not a reliable pump for this.
            //
            // Once the window keeps up with the pointer, the pointer stops
            // moving relative to the view it is dragging, and a gesture that
            // reports view-relative movement has little left to report. The
            // monitor sees the mouse itself, so the panel keeps up for as
            // long as the button is down.
            stopFollowing()
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                self?.followPointer()
                return event
            }
        case .changed:
            followPointer()
        case .ended:
            stopFollowing()
            dragOrigin = nil
            dragPointerOrigin = nil
            AppSettings.shared.panelAnchor = anchor
        }
    }

    private func followPointer() {
        guard let dragOrigin, let dragPointerOrigin else { return }
        let pointer = NSEvent.mouseLocation
        anchor = CGPoint(x: dragOrigin.x + (pointer.x - dragPointerOrigin.x),
                         y: dragOrigin.y + (pointer.y - dragPointerOrigin.y))
        panel?.setFrame(targetFrame(), display: false)
    }

    private func stopFollowing() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        guard !panel.isVisible else { return }

        // Enters from off the right edge. A panel that simply appears at full
        // opacity reads as a notification; sliding in from the side it will
        // live at reads as something docking.
        let destination = panel.frame
        var offscreen = destination
        offscreen.origin.x += 28
        panel.setFrame(offscreen, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(destination, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        var offscreen = panel.frame
        offscreen.origin.x += 28
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().setFrame(offscreen, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Follows the content. SwiftUI reports what it laid out, and the window
    /// is made to match it, in both directions: collapsed to the mark the
    /// panel is eighty points wide, and the rest of the strip must not be an
    /// invisible window sitting over whatever is behind it.
    private func resize(to content: CGSize) {
        let targetWidth = min(max(content.width + 28, 80), 520)
        let targetHeight = min(max(content.height + 28, 60), 780)
        guard abs(targetWidth - width) > 0.5 || abs(targetHeight - height) > 0.5 else { return }
        width = targetWidth
        height = targetHeight
        guard let panel else { return }
        let frame = targetFrame()
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: false)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // SwiftUI draws one shaped to the card
        // Moved by its own gesture rather than by AppKit's background drag,
        // which a button filling the whole pill would swallow anyway.
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = LivePanelView(
            onSize: { [weak self] measured in self?.resize(to: measured) },
            onDrag: { [weak self] phase in self?.drag(phase) }
        )
        let host = NSHostingView(rootView: root.environmentObject(session))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        panel.setFrame(targetFrame(), display: false)
    }
}

// MARK: - The panel

/// What a drag of the panel is doing, reported to the controller that owns
/// the window.
enum PanelDrag {
    case began
    case changed
    case ended
}

/// Makes a view drag the whole panel around, and optionally click.
///
/// One gesture decides between the two rather than two gestures competing.
/// Layering a drag over a `Button` does not work here: the button still fires
/// on mouse-up, so putting the panel down somewhere would also open it, and
/// pre-empting the button with a high-priority gesture takes its press away
/// altogether. A single drag that measures how far it travelled can tell a
/// click from a move, which is the distinction that actually matters.
private struct Movable: ViewModifier {
    let onDrag: (PanelDrag) -> Void
    /// Run when the pointer went down and up without really moving.
    var onClick: (() -> Void)?

    /// How far the pointer may wander and still count as a click.
    private static let slop: CGFloat = 3

    @State private var moving = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !moving,
                       hypot(value.translation.width, value.translation.height) > Self.slop {
                        moving = true
                        onDrag(.began)
                    }
                    if moving { onDrag(.changed) }
                }
                .onEnded { _ in
                    if moving {
                        moving = false
                        onDrag(.ended)
                    } else {
                        onClick?()
                    }
                }
        )
    }
}

private struct LivePanelView: View {
    let onSize: (CGSize) -> Void
    let onDrag: (PanelDrag) -> Void
    @EnvironmentObject private var session: LiveSession

    /// An offer has to be read to be answered, so it is never collapsed.
    private var isCollapsed: Bool {
        !session.isPanelExpanded && session.offer == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                CollapsedMark(onDrag: onDrag)
            } else if session.offer != nil && !session.isRunning {
                OfferCard().modifier(Movable(onDrag: onDrag))
            } else {
                SessionCard(onDrag: onDrag)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelSizeKey.self, value: geometry.size)
            }
        }
        .onPreferenceChange(PanelSizeKey.self) { onSize($0) }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(Theme.spring, value: session.isRunning)
        .animation(Theme.spring, value: session.offer)
        .animation(Theme.spring, value: session.isPanelExpanded)
    }
}

/// The collapsed panel: the product mark, and nothing else.
///
/// What sits at the edge of the screen for an hour should say two things and
/// no more: this is running, and someone is talking. The mark says both, and
/// tints itself for whichever side is louder, so a glance tells you the call
/// is still going and who is holding the floor. Everything else is one click
/// away.
private struct CollapsedMark: View {
    let onDrag: (PanelDrag) -> Void
    @EnvironmentObject private var session: LiveSession
    @State private var hovering = false

    private var accent: Color {
        session.markVoice == .you ? Theme.live : Theme.liveSoft
    }

    var body: some View {
        SpeakingMark(history: session.markHistory,
                     active: session.isRunning,
                     accent: accent)
            .frame(height: 20)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background {
                // Flat and opaque. A blur material picks up whatever is
                // behind it, and a wide soft shadow spreads a halo out from
                // the edge; against a light window the two together read as a
                // smudge around the mark rather than as something resting on
                // top of one.
                Capsule()
                    .fill(Theme.raised)
                    .overlay {
                        Capsule().strokeBorder(
                            hovering ? Theme.hover : Theme.border,
                            lineWidth: 1
                        )
                    }
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
            }
            .scaleEffect(hovering ? 1.045 : 1)
            .contentShape(Capsule())
            .modifier(Movable(onDrag: onDrag, onClick: { session.isPanelExpanded = true }))
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
            .help("Click to open, drag to move")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open the session")
            .accessibilityAction { session.isPanelExpanded = true }
            .transition(.scale(scale: 0.86, anchor: .topTrailing).combined(with: .opacity))
    }
}

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width),
                       height: max(value.height, next.height))
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shown when a call has started and nothing is capturing it.
private struct OfferCard: View {
    @EnvironmentObject private var session: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                PulsingDot(active: true, size: 6)
                    .frame(width: 18, height: 18)
                Text("\(session.offer ?? "A call") started")
                    .font(Theme.medium(13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            Text("Want \(Brand.name) to take notes? It transcribes you and the room separately, on this Mac.")
                .font(Theme.body(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Listen in") { session.acceptOffer() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Not now") { session.declineOffer() }
                    .buttonStyle(GhostButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .frame(width: 316)
        .panelCard(glowing: true)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// Shown while a session runs, and briefly after it ends.
private struct SessionCard: View {
    let onDrag: (PanelDrag) -> Void
    @EnvironmentObject private var session: LiveSession
    @State private var contentHeight: CGFloat = 34

    /// Past this the transcript scrolls instead of growing, so a long meeting
    /// does not end up as a panel the height of the screen.
    private static let transcriptLimit: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            traces
            Divider().overlay(Theme.borderSoft)
            transcript
            footer
        }
        .frame(width: 356)
        .panelCard(glowing: session.isRunning)
        .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            // The title strip is the handle. The drag deliberately stops short
            // of the controls beside it: a gesture covering the whole header
            // would have to decide between moving the panel and pressing
            // Stop, and getting that wrong ends a recording.
            HStack(spacing: 8) {
                PulsingDot(active: session.isRunning, size: 6)
                    .frame(width: 18, height: 18)

                Text(session.isRunning ? session.trigger.label : session.trigger.pastLabel)
                    .font(Theme.medium(13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                ElapsedLabel(since: session.startedAt,
                             frozen: session.isRunning ? nil : session.finalDuration,
                             tint: Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .modifier(Movable(onDrag: onDrag))
            .help("Drag to move")

            Button {
                session.isPanelExpanded = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background { Circle().fill(Theme.hover) }
            }
            .buttonStyle(.plain)
            .help("Collapse")

            Button {
                session.isRunning ? session.stop() : session.dismissPanel()
            } label: {
                Image(systemName: session.isRunning ? "stop.fill" : "xmark")
                    .font(.system(size: session.isRunning ? 9 : 10, weight: .bold))
                    .foregroundStyle(session.isRunning ? Theme.base : Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background {
                        Circle().fill(session.isRunning ? Theme.accentFill : Theme.hover)
                    }
            }
            .buttonStyle(.plain)
            .disabled(session.isStopping)
        }
        .padding(.bottom, 12)
    }

    // MARK: Traces

    private var traces: some View {
        VStack(spacing: 10) {
            trace(label: "You",
                  history: session.youHistory,
                  tint: Theme.live,
                  live: session.hearsYou,
                  speaking: !session.youDraft.isEmpty)
            trace(label: roomLabel,
                  history: session.roomHistory,
                  tint: Theme.liveSoft,
                  live: session.hearsRoom,
                  speaking: !session.roomDraft.isEmpty)
        }
        .padding(.bottom, 12)
    }

    private var roomLabel: String {
        if case .meeting(let app) = session.trigger { return app }
        return "Mac"
    }

    private func trace(label: String, history: [Float], tint: Color, live: Bool, speaking: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.medium(10))
                .foregroundStyle(speaking ? tint : Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(Theme.quick, value: speaking)

            // A source that never opened is drawn as off rather than as
            // silent: a flat line otherwise claims a microphone is listening
            // on a Mac that has none.
            VoiceTrace(history: history, active: session.isRunning && live, tint: tint)
                .frame(height: 26)
                .opacity(live || !session.isRunning ? 1 : 0.3)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.lines.isEmpty && drafts.isEmpty {
                        Text(session.isRunning ? "Waiting for the first words…" : "Nothing was heard.")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.vertical, 10)
                    }

                    ForEach(session.lines) { line in
                        LineRow(voice: line.voice, text: line.text, settled: true)
                            .id(line.id)
                    }

                    ForEach(drafts, id: \.0) { voice, text in
                        LineRow(voice: voice, text: text, settled: false)
                            .id("draft-\(voice.rawValue)")
                    }

                    // Scroll anchor. Pinning to the last line leaves the
                    // bottom of it against the edge; an empty view below gives
                    // the list somewhere to rest.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .onPreferenceChange(TranscriptHeightKey.self) { measured in
                guard abs(measured - contentHeight) > 0.5 else { return }
                withAnimation(Theme.spring) { contentHeight = measured }
            }
            .frame(height: min(Self.transcriptLimit, max(34, contentHeight)))
            .scrollIndicators(.never)
            .mask {
                // Lines dissolve at the top edge instead of being cut off by
                // it, so the panel reads as a window onto something still
                // running.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.07),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .onChange(of: session.lines.count) { _, _ in
                withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.youDraft) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.roomDraft) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// The unsettled tail of each stream, in the order they are speaking.
    private var drafts: [(LiveSession.Voice, String)] {
        var out: [(LiveSession.Voice, String)] = []
        if !session.roomDraft.isEmpty { out.append((.room, session.roomDraft)) }
        if !session.youDraft.isEmpty { out.append((.you, session.youDraft)) }
        return out
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let message = session.statusMessage {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }

        if session.isStopping {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing up…")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        } else if !session.isRunning, session.savedTranscript != nil {
            HStack(spacing: 8) {
                Button("Open transcript") { session.openSaved() }
                    .buttonStyle(PrimaryButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

private struct LineRow: View {
    let voice: LiveSession.Voice
    let text: String
    let settled: Bool

    private var tint: Color { voice == .you ? Theme.live : Theme.liveSoft }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // A rail rather than a name on every line: the colour already says
            // who is speaking, and a repeated label down the left edge costs
            // width the words need.
            Capsule()
                .fill(tint.opacity(settled ? 0.75 : 0.35))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            Text(text)
                .font(Theme.body(12.5))
                .foregroundStyle(settled ? Theme.textPrimary : Theme.textSecondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .transition(.asymmetric(
            insertion: .offset(y: 10).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// MARK: - Card chrome

private extension View {
    /// The shared panel surface: translucent, bordered, and faintly lit from
    /// within while something is live.
    func panelCard(glowing: Bool) -> some View {
        self
            .padding(16)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.radiusPanel + 4, style: .continuous)
                shape
                    .fill(Theme.surface)
                    .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            }
            .animation(Theme.quick, value: glowing)
    }
}
