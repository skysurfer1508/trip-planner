import SwiftUI

/// The app's empty state: a thin wrapper over `ContentUnavailableView` so every screen words and
/// lays it out the same way. One optional primary action.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary(fullWidth: false))
            }
        }
    }
}
