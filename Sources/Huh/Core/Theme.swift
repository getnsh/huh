import SwiftUI

/// Design tokens.
///
/// The palette is monochrome with a single saturated accent. Colour carries
/// meaning rather than decoration: `live` denotes active state and is used
/// nowhere else.
///
/// Greys form an explicit ladder rather than ad-hoc opacities, so layered
/// surfaces compose predictably: base < surface < raised < hover.
enum Theme {

    // MARK: Colour

    static let base       = Color(hex: 0x0A0A0A)   // window background
    static let surface    = Color(hex: 0x121212)   // sidebar, bars
    static let raised     = Color(hex: 0x191919)   // cards, rows
    static let hover      = Color(hex: 0x222222)   // row hover
    static let pressed    = Color(hex: 0x2B2B2B)

    static let border     = Color(hex: 0x262626)
    static let borderSoft = Color(hex: 0x1C1C1C)

    static let textPrimary   = Color(hex: 0xECECEC)
    static let textSecondary = Color(hex: 0x9B9B9B)
    static let textTertiary  = Color(hex: 0x6B6B6B)

    /// Active state: recording, processing, confirmed. The only saturated
    /// colour in the palette.
    static let live       = Color(hex: 0x9E7BFF)
    /// A lighter step, for gradient falloff and secondary marks.
    static let liveSoft   = Color(hex: 0xC4B0FF)
    static let warning    = Color(hex: 0xE0A458)
    static let danger     = Color(hex: 0xE5534B)

    /// Primary buttons are light-on-dark.
    static let accentFill = Color(hex: 0xF5F5F5)
    static let accentText = Color(hex: 0x0A0A0A)

    // MARK: Type
    //
    // The system font is used throughout: it is the only face guaranteed to be
    // metrically correct at every size on every installation, and it matches the
    // surrounding platform chrome.

    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
    static func heading(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .regular) }
    static func medium(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium) }
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

    // MARK: Metrics

    static let radiusControl: CGFloat = 8
    static let radiusCard: CGFloat = 12
    static let radiusPanel: CGFloat = 16

    // MARK: Motion
    //
    // Two curves only, so that motion reads as a single coherent system.

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
