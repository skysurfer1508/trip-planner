import SwiftUI

/// Text roles. All of them are built on Dynamic Type text styles, so they scale up to AX5 without
/// any extra work. Titles, numbers and pins use SF Rounded, running text uses SF Pro.
///
/// Prefer `.textRole(.title)` or `.eyebrow()` over hand-written `.font(...)` chains.
enum Typography {
    static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    static let headline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let body = Font.body
    static let label = Font.subheadline.weight(.medium)
    static let caption = Font.caption
    static let eyebrow = Font.caption.weight(.semibold)
    /// Countdowns, prices, distances. Tabular digits so numbers don't jiggle while they change.
    static let numeric = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
}

enum TextRole {
    case display, title, headline, body, label, caption, eyebrow, numeric

    var font: Font {
        switch self {
        case .display: Typography.display
        case .title: Typography.title
        case .headline: Typography.headline
        case .body: Typography.body
        case .label: Typography.label
        case .caption: Typography.caption
        case .eyebrow: Typography.eyebrow
        case .numeric: Typography.numeric
        }
    }

    var color: Color {
        switch self {
        case .display, .title, .headline, .body, .numeric: Theme.ink
        case .label, .caption, .eyebrow: Theme.inkSecondary
        }
    }
}

extension View {
    /// Applies the font and the matching text colour of a role.
    func textRole(_ role: TextRole) -> some View {
        font(role.font).foregroundStyle(role.color)
    }

    /// Small uppercase label above a title or section ("DAY 2", "NEXT UP").
    func eyebrow() -> some View {
        font(Typography.eyebrow)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Theme.inkSecondary)
    }
}
