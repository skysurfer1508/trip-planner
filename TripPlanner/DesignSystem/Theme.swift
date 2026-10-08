import SwiftUI

/// Semantic colour roles for the whole app ("Calm modern" direction, see docs/DESIGN_SYSTEM.md).
///
/// Every colour is an Asset Catalog colour set with four variants: light, dark, light + Increase
/// Contrast, dark + Increase Contrast. Views should use these roles and never colour literals such
/// as `.orange` or `Color(red:...)`.
///
/// Contrast (checked for all four variants when the sets were generated):
/// - `ink` and `inkSecondary` on `background`, `surface` and `surfaceRaised`: at least 4.5:1.
/// - `accent`, `success`, `warning`, `danger`, `info` as text or glyph on `surface`: at least 4.5:1.
/// - `onAccent` on `accent` and on every day colour: at least 4.5:1.
enum Theme {
    // Surfaces
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    /// Hairlines and card edges. Decorative, not for text.
    static let separator = Color("Separator")

    // Text
    static let ink = Color("Ink")
    static let inkSecondary = Color("InkSecondary")

    // Accent: the global accent colour (AccentColor asset). Use it for primary actions and selection only.
    static let accent = Color("AccentColor")
    /// Text and glyphs that sit on `accent` or on a day colour.
    static let onAccent = Color("OnAccent")

    // Status. Always pair these with an icon or text, never colour alone.
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
    static let info = Color("Info")
}

// MARK: - Days and stop categories

extension Theme {
    /// Number of distinct day colours. Days after that cycle.
    static let dayColorCount = 8

    /// A day is a SOLID colour: its pill, its route line and its map pins. Text on it is `onAccent`.
    /// Days never share a hue family role with stop categories (those are glyph tints on a neutral
    /// surface, see `category(_:)`).
    static func day(_ index: Int) -> Color {
        let slot = ((index % dayColorCount) + dayColorCount) % dayColorCount
        return Color("Day\(slot + 1)")
    }

    /// A stop category is a TINT for its glyph on a neutral surface (list rows, chips). It is never a
    /// pin or route fill. The glyph shape carries the meaning, the tint only supports it.
    static func category(_ category: StopCategory) -> Color {
        switch category {
        case .sight: Color("CatSight")
        case .food: Color("CatFood")
        case .cafe: Color("CatCafe")
        case .hotel: Color("CatHotel")
        case .transport: Color("CatTransport")
        case .nightlife: Color("CatNightlife")
        case .other: Color("CatOther")
        }
    }
}
