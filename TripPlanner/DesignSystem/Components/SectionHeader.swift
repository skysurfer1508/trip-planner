import SwiftUI

/// A section title with an optional eyebrow above it and an optional text action on the right
/// ("See all"). Marked as a heading for VoiceOver.
struct SectionHeader: View {
    let title: String
    var eyebrow: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow).eyebrow()
                }
                Text(title)
                    .font(Typography.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Spacing.s)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typography.label)
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }
}
