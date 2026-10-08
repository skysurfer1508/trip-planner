import SwiftUI

enum BannerKind {
    case info, warning, danger, success

    var color: Color {
        switch self {
        case .info: Theme.info
        case .warning: Theme.warning
        case .danger: Theme.danger
        case .success: Theme.success
        }
    }

    /// Each kind has its own glyph, so the meaning never depends on colour alone.
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    /// Spoken before the title by VoiceOver.
    var spokenName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .danger: "Problem"
        case .success: "Done"
        }
    }
}

/// An inline notice (weather warning, reflow suggestion, offline note). Replaces every hand-made
/// orange/blue tinted banner. Text is `ink` on a faint tint of the kind colour, the glyph is the
/// kind colour. Optional actions go underneath.
struct Banner<Actions: View>: View {
    let kind: BannerKind
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        let shape = Radius.shape(Radius.card)
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Theme.inkSecondary)
                }
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.l)
        .background(Theme.surface, in: shape)
        .background(kind.color.opacity(0.12), in: shape)
        .overlay(shape.strokeBorder(kind.color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.spokenName). \(title)")
    }
}

extension Banner where Actions == EmptyView {
    init(kind: BannerKind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}
