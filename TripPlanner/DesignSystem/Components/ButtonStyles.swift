import SwiftUI

/// The one filled button per screen: Navigate, Done, Add place, Continue. Accent fill, `onAccent`
/// text, at least 50 pt tall. Do not put glass on this, glass is for floating controls only.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .foregroundStyle(Theme.onAccent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 50)
            .background(Theme.accent, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The calm alternative next to a primary button: surface fill, accent text, hairline edge.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .foregroundStyle(Theme.accent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 50)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(fullWidth: Bool) -> PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(fullWidth: Bool) -> SecondaryButtonStyle { SecondaryButtonStyle(fullWidth: fullWidth) }
}
