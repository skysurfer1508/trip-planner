import SwiftUI

/// A large single-choice card. Selected: accent border and a filled checkmark, so it never relies on
/// colour alone.
struct OptionCard: View {
    let title: String
    var detail: String?
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: Spacing.l) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.inkSecondary)
                    .symbolEffect(.bounce, value: isSelected)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(Spacing.m)
            .background(isSelected ? Theme.accent.opacity(0.1) : Theme.surface, in: Radius.shape(Radius.card))
            .overlay(
                Radius.shape(Radius.card)
                    .strokeBorder(isSelected ? Theme.accent : Theme.separator, lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(Radius.shape(Radius.card))
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A square-ish multi-select tile with an icon. When on it fills with the accent and shows a checkmark.
struct SelectTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typography.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(Spacing.s)
            .background(isOn ? Theme.accent : Theme.surface, in: Radius.shape(Radius.card))
            .overlay(Radius.shape(Radius.card).strokeBorder(isOn ? Color.clear : Theme.separator, lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .padding(Spacing.s)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.ink)
            .contentShape(Radius.shape(Radius.card))
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Title, subtitle and scrolling content for one question.
struct QuestionPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(title)
                        .font(Typography.display)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                content()
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}
