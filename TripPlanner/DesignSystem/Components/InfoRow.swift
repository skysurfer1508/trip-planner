import SwiftUI

/// A glyph, a title and an optional detail line, with an optional trailing view. Replaces
/// `MoreView.row`, `logisticsCard` and `logisticsToday`. The glyph is plain (no badge behind it)
/// and its column scales with Dynamic Type.
struct InfoRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Typography.label)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}
