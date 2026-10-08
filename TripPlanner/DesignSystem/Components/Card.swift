import SwiftUI

/// The one card style. Solid surface, continuous 20 pt corners, a hairline edge, no glass.
/// Replaces the old `.thinMaterial` `.card()`.
///
/// Use `Card { ... }` for new code, or `.card()` on an existing stack. Use `elevation: .raised`
/// only for the single most important card on a screen.
struct CardStyle: ViewModifier {
    var padding: CGFloat = Spacing.l
    var radius: CGFloat = Radius.card
    var elevation: Elevation = .none
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = Radius.shape(radius)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: contrast == .increased ? 1.5 : 0.5))
            .elevation(elevation)
    }
}

extension View {
    func card(padding: CGFloat = Spacing.l, elevation: Elevation = .none) -> some View {
        modifier(CardStyle(padding: padding, elevation: elevation))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.l
    var elevation: Elevation = .none
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().card(padding: padding, elevation: elevation)
    }
}
