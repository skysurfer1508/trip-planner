import SwiftUI

/// The title row at the top of a tab (Plan, Discover, Budget, More) with its actions on the right.
///
/// It is drawn as part of the page, not as a navigation toolbar: SwiftUI does not show toolbar items or
/// large titles that are declared inside the tabs of a `TabView`, only the ones on the `TabView` itself.
/// Put it in `.safeAreaInset(edge: .top)` or at the top of a stack, and style each action with
/// `.headerAction()` so it has a 44 pt target.
struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))

        layout {
            Text(title)
                .font(Typography.display)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.s) {
                actions()
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

extension View {
    /// A header button: accent glyph or text on a pill with a hairline, at least 44 x 44 pt.
    func headerAction() -> some View {
        font(Typography.label)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Spacing.m)
            .frame(minWidth: 44, minHeight: 44)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 0.5))
            .contentShape(Capsule())
    }
}
