import SwiftUI

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.medium(13))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(Theme.accentFill.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.medium(13))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.medium(12))
            .foregroundStyle(configuration.isPressed ? Theme.textPrimary : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.hover : Color.clear)
            )
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

// MARK: - Search

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .animation(Theme.quick, value: text.isEmpty)
    }
}

struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.medium(11))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono : Theme.body(14))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .fill(Theme.base)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        }
    }
}

// MARK: - Small pieces

struct Chip: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(filled ? Theme.accentText : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.12))
            )
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(Theme.heading(14))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Row hover highlight, keyed centrally in `UIState`.
struct HoverHighlight: ViewModifier {
    @ObservedObject private var ui = UIState.shared
    let id: String
    var radius: CGFloat = Theme.radiusCard

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(ui.hovered == id ? Theme.hover : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ui.hovered == id ? Theme.border : Theme.borderSoft, lineWidth: 1)
            )
            .onHover { inside in
                withAnimation(Theme.quick) {
                    if inside { ui.hovered = id } else if ui.hovered == id { ui.hovered = nil }
                }
            }
    }
}

extension View {
    func hoverHighlight(_ id: String, radius: CGFloat = Theme.radiusCard) -> some View {
        modifier(HoverHighlight(id: id, radius: radius))
    }

    var isHovered: Bool { UIState.shared.hovered != nil }
}

// MARK: - Level meter
//
// Shared by the overlay and the main window's transport bar so that input level
// is presented identically in both.

struct LevelBars: View {
    let history: [Float]
    let barCount: Int
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2.5
    var maxHeight: CGFloat = 24
    let active: Bool
    var tint: Color = Theme.live

    static func width(barCount: Int, barWidth: CGFloat = 3, barSpacing: CGFloat = 2.5) -> CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(fill(for: index))
                        .frame(width: barWidth, height: height(for: index, phase: phase))
                }
            }
        }
    }

    private func level(at index: Int) -> Double {
        let offset = index - (barCount - history.count)
        guard offset >= 0, offset < history.count else { return 0 }
        return Double(history[offset])
    }

    private func height(for index: Int, phase: TimeInterval) -> CGFloat {
        // Compress the upper range so loud speech does not saturate every bar.
        let shaped = pow(min(1, level(at: index)), 0.65)
        // Idle animation: a static row reads as a failure rather than as
        // waiting for input.
        let breathing = active ? 2.2 * (0.5 + 0.5 * sin(phase * 3.1 + Double(index) * 0.42)) : 0
        return 3 + CGFloat(breathing) + CGFloat(shaped) * (maxHeight - 3)
    }

    private func fill(for index: Int) -> Color {
        guard active else { return Theme.textTertiary.opacity(0.45) }
        let recency = Double(index) / Double(max(1, barCount - 1))
        return tint.opacity(0.35 + 0.65 * recency)
    }
}

// MARK: - Intelligence requirement

/// Explains why a model-backed feature is unavailable, and offers the action
/// that resolves it.
///
/// Presented in place of the feature rather than by disabling a control. A
/// disabled control with a tooltip communicates almost nothing: the requirement
/// is invisible, and so is the fact that everything else still works.
struct IntelligenceNotice: View {
    @ObservedObject private var model = ModelAvailability.shared
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(Theme.medium(compact ? 12 : 12.5))
                    .foregroundStyle(Theme.textPrimary)
                Text(model.detail)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let action = model.actionTitle {
                Button(action) { model.performAction() }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.textPrimary))
            }
        }
        .padding(compact ? 10 : 12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private var symbol: String {
        switch model.state {
        case .downloading: return "arrow.down.circle"
        case .notEligible: return "info.circle"
        default:           return "sparkles"
        }
    }

    private var tint: Color {
        switch model.state {
        case .notEligible: return Theme.textTertiary
        default:           return Theme.warning
        }
    }
}

/// A bar that shows work is happening without claiming to know how much is
/// left. Used wherever the honest answer is "running", such as a language model
/// generating text, where any percentage would be invented.
struct IndeterminateBar: View {
    @ObservedObject private var motion = Motion.shared

    private final class Motion: ObservableObject {
        static let shared = Motion()
        @Published var phase: CGFloat = 0
        private var timer: Timer?
        private init() {
            // A timer rather than `repeatForever`, which cannot be driven from
            // an ObservableObject without the animation property wrappers this
            // toolchain does not provide.
            timer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    withAnimation(.easeInOut(duration: 1.05)) {
                        self.phase = self.phase == 0 ? 1 : 0
                    }
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 0.35
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hover)
                Capsule()
                    .fill(Theme.live)
                    .frame(width: width)
                    .offset(x: motion.phase * (geo.size.width - width))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Live audio

/// Scales a window of levels against its own recent peak.
///
/// Raw levels are honest and nearly useless to look at. A microphone a foot
/// from a mouth and a video playing at a third of the system volume differ by
/// more than an order of magnitude, so a meter drawn from the raw figure is
/// either pinned or flat depending on the source. Dividing by the loudest
/// thing in the visible window gives a trace that uses its full height
/// whatever it is listening to, and the floor stops genuine silence from being
/// amplified into a signal.
enum LevelScale {
    /// Below this, a window is treated as silence rather than as something
    /// quiet worth magnifying.
    static let floor: Float = 0.06

    static func reference(_ history: [Float]) -> Float {
        max(history.max() ?? 0, floor)
    }

    static func normalised(_ value: Float, in history: [Float]) -> Double {
        Double(min(1, max(0, value / reference(history))))
    }
}

/// A mirrored level trace: bars grow out from a centre line, newest on the
/// right, older bars fading toward the left.
///
/// `LevelBars` reads as a meter, which is right for a status pill. A session
/// panel is watched for an hour, and wants something closer to a signal: a
/// trace that is legible at a glance as sound arriving, and quiet when it is
/// not. Drawn in a `Canvas` rather than as a stack of shapes because there are
/// two of these on screen at once, redrawing thirty times a second.
struct VoiceTrace: View {

    let history: [Float]
    let active: Bool
    var barCount: Int = 44
    var tint: Color = Theme.live
    var spacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let barWidth = max(1.5, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                let middle = size.height / 2

                var path = Path()
                for index in 0..<barCount {
                    let amount = amplitude(at: index, phase: phase)
                    let height = max(barWidth, amount * size.height)
                    let x = CGFloat(index) * (barWidth + spacing)
                    path.addRoundedRect(
                        in: CGRect(x: x, y: middle - height / 2, width: barWidth, height: height),
                        cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                    )
                }

                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [tint.opacity(0.14), tint.opacity(0.55), tint]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )

                // The glow is the same path drawn blurred underneath, so loud
                // passages bloom and quiet ones do not.
                if active && !reduceMotion {
                    var glow = context
                    glow.addFilter(.blur(radius: 5))
                    glow.opacity = 0.6
                    glow.fill(path, with: shading)
                }
                context.opacity = active ? 1 : 0.35
                context.fill(path, with: shading)
            }
        }
    }

    private func amplitude(at index: Int, phase: TimeInterval) -> Double {
        let offset = index - (barCount - history.count)
        let level = (offset >= 0 && offset < history.count)
            ? LevelScale.normalised(history[offset], in: history)
            : 0
        // Compress the upper range so loud speech does not saturate the trace.
        let shaped = pow(min(1, level), 0.65)
        // A flat line reads as broken rather than as silence.
        let idle = (active && !reduceMotion)
            ? 0.045 * (0.5 + 0.5 * sin(phase * 2.6 + Double(index) * 0.5))
            : 0
        return min(1, shaped * 0.92 + idle)
    }
}

/// A dot with a ring expanding out of it: something is running.
struct PulsingDot: View {

    let active: Bool
    var tint: Color = Theme.live
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                .frame(width: size, height: size)
                .scaleEffect(expanded ? 2.8 : 1)
                .opacity(expanded ? 0 : 0.9)
            Circle()
                .fill(active ? tint : Theme.textTertiary)
                .frame(width: size, height: size)
                .shadow(color: tint.opacity(active ? 0.9 : 0), radius: 5)
        }
        .frame(width: size * 3, height: size * 3)
        .onAppear { animate() }
        .onChange(of: active) { _, _ in animate() }
    }

    private func animate() {
        guard active, !reduceMotion else {
            expanded = false
            return
        }
        expanded = false
        withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}

/// Elapsed time, ticking. Monospaced digits so the panel does not reflow every
/// second.
struct ElapsedLabel: View {
    let since: Date?
    /// A fixed length to show instead of counting. Set once something has
    /// stopped, so the readout holds at what it reached.
    var frozen: TimeInterval?
    var font: Font = Theme.medium(12)
    var tint: Color = Theme.textSecondary

    var body: some View {
        if let frozen {
            label(for: frozen)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                label(for: since.map { timeline.date.timeIntervalSince($0) } ?? 0)
            }
        }
    }

    private func label(for interval: TimeInterval) -> some View {
        Text(Self.format(interval))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(tint)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The product mark, moving to whoever is speaking.
///
/// The same five capsules as the application icon, at the same weights, so at
/// rest it is the logo and not an approximation of it: the collapsed panel has
/// to be recognisable as this application sitting at the edge of the screen,
/// and a generic meter would not be. Sound lifts the bars out of their resting
/// heights, each on its own phase so it reads as speech rather than as a level
/// meter, and the centre bar carries the accent exactly as the icon does.
struct SpeakingMark: View {

    /// The recent levels of whatever is being listened to.
    let history: [Float]
    let active: Bool
    /// Tints the centre bar. Which source is speaking is worth a colour.
    var accent: Color = Theme.live
    var barWidth: CGFloat = 3.5
    var gap: CGFloat = 3.5
    var maxHeight: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The icon's own proportions.
    private let weights: [Double] = [0.34, 0.66, 1.0, 0.66, 0.34]
    /// How tall the bars stand with nothing to hear. Below this the mark stops
    /// looking like the logo; much above it, speech has nowhere to go.
    private let rest: Double = 0.44

    /// The loudest of the last few samples rather than the latest one. A
    /// glyph this small sampled on single frames flickers; a short peak hold
    /// reads as a voice.
    private var level: Double {
        let recent = history.suffix(4)
        guard let peak = recent.max() else { return 0 }
        return LevelScale.normalised(peak, in: history)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<weights.count, id: \.self) { index in
                    Capsule()
                        .fill(index == 2 ? accent : Theme.textPrimary)
                        .frame(width: barWidth, height: height(index, phase))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: accent)
    }

    private func height(_ index: Int, _ phase: TimeInterval) -> CGFloat {
        let weight = weights[index]
        let shaped = pow(min(1, max(0, level)), 0.6)
        // Each bar leads or lags the others slightly, which is what separates
        // a voice from a volume reading.
        let wobble = (active && !reduceMotion)
            ? 0.78 + 0.22 * sin(phase * 7.4 + Double(index) * 1.15)
            : 1
        let fraction = rest + (1 - rest) * shaped * wobble
        return max(barWidth, CGFloat(weight * fraction) * maxHeight)
    }
}
