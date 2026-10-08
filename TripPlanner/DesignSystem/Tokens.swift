import SwiftUI

/// The 4-pt spacing scale. Use these instead of numeric literals in `.padding`, `spacing:` etc.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Exactly three corner radii. Always paired with `.continuous` corners via `Radius.shape(_:)`.
enum Radius {
    /// Chips, thumbnails, small controls.
    static let small: CGFloat = 10
    /// Cards, banners, sheets' inner blocks.
    static let card: CGFloat = 20
    /// Hero images and the largest surfaces.
    static let hero: CGFloat = 28

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// How far a surface floats. At most two shadow recipes exist.
enum Elevation {
    /// Flat: lists, rows, anything inside a card.
    case none
    /// A card resting on the background. Soft shadow in light mode, no shadow in dark mode (the
    /// lighter surface already separates it).
    case raised
    /// Things that float above content: action buttons, bottom sheets' grabbers, callouts.
    case floating
}

private struct ElevationModifier: ViewModifier {
    let level: Elevation
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch level {
        case .none:
            content
        case .raised:
            content.shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 12, x: 0, y: 4)
        case .floating:
            content.shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 20, x: 0, y: 8)
        }
    }
}

extension View {
    func elevation(_ level: Elevation) -> some View {
        modifier(ElevationModifier(level: level))
    }
}
