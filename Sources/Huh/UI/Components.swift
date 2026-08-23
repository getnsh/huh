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
