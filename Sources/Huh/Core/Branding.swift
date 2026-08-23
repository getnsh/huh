import SwiftUI

/// Product identity. All user-visible naming is defined here so that rebranding
/// requires changing a single file. `productName` must remain in sync with
/// `Resources/Info.plist` and `scripts/build.sh`.
enum Brand {
    /// What people see: menu bar, About box, window title, Finder.
    static let name = "huh?"

    /// Filesystem-safe identifier. The display name contains "?", which is both
    /// a shell glob and a regular-expression metacharacter; using it in
    /// executable names, script paths or process-matching patterns produces
    /// incorrect matches. All path-shaped values use this instead.
    static let productName = "Huh"

    /// Previous product name, retained solely for data migration.
    static let legacyProductName = "Murmur"

    static let tagline = "Hold. Speak. It's typed."
    static let bundleID = "com.getnsh.huh"

    // Menu bar glyph per state.
    static let idleSymbol = "waveform"
    static let listeningSymbol = "waveform.circle.fill"
    static let workingSymbol = "waveform.badge.magnifyingglass"
    static let errorSymbol = "waveform.slash"

    // Retained for source compatibility; the palette is defined in Theme.
    static let accent = Theme.live
    static let accentSoft = Theme.liveSoft
    static let danger = Theme.danger
}
