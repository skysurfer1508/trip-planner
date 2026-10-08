import SwiftUI

/// The ONLY place in the app that uses Liquid Glass (see docs/LiquidGlassReference.md).
///
/// Glass is for the floating navigation layer: floating action buttons, toolbars, bottom accessories.
/// Never use it on content cards, lists, or text over photos, and never put glass inside glass.
///
/// - iOS 26+ (built with the Xcode 26 SDK): `glassEffect`.
/// - Earlier iOS, or an older SDK: `.thinMaterial`.
/// - Reduce Transparency: a solid raised surface with a hairline, on every version.
struct FloatingChrome<S: Shape>: ViewModifier {
    let shape: S
    /// Only primary actions are tinted.
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? Theme.surfaceRaised, in: shape)
                .overlay(shape.stroke(Theme.separator, lineWidth: 1))
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
        #else
        content.background(.thinMaterial, in: shape)
        #endif
    }
}

extension View {
    /// Wraps a floating control (button, accessory) in the app's chrome material, as a capsule.
    func floatingChrome(tint: Color? = nil) -> some View {
        modifier(FloatingChrome(shape: Capsule(), tint: tint))
    }

    /// Same, in any shape (a circle for round buttons, a rounded rectangle for accessories).
    func floatingChrome<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(FloatingChrome(shape: shape, tint: tint))
    }
}

/// A round floating action button (for example "I'm hungry" on Today). 56 pt minimum, scales with
/// Dynamic Type, and always has an accessibility label.
struct FloatingActionButton: View {
    let symbol: String
    let label: String
    /// Tint it only when this is the screen's primary action.
    var isPrimary = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 56

    var body: some View {
        Button {
            Haptics.impact(.medium)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isPrimary ? Theme.onAccent : Theme.ink)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .floatingChrome(in: Circle(), tint: isPrimary ? Theme.accent : nil)
        .elevation(.floating)
        .accessibilityLabel(label)
    }
}
