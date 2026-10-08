import SwiftUI

/// A title with action buttons at the top of a tab. The actions live in the screen itself, because
/// the navigation bar around the tabs can drop the buttons that tabs ask it to show.
struct TabHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Spacing.l) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            actions()
                .font(.title3)
        }
        .padding(.horizontal)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
