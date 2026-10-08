import SwiftUI

/// A large single-choice card.
struct OptionCard: View {
    let title: String
    var detail: String?
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.l) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(isSelected ? 0.25 : 0.1),
                                in: Radius.shape(Radius.small))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(Spacing.m)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground),
                        in: Radius.shape(Radius.card))
            .overlay(
                Radius.shape(Radius.card)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A square-ish multi-select tile with an icon.
struct SelectTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(Spacing.s)
            .background(isOn ? Color.accentColor : Color(.secondarySystemBackground),
                        in: Radius.shape(Radius.card))
            .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
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
                        .font(.title.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
