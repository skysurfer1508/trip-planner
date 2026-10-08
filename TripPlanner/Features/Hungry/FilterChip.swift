import SwiftUI

struct FilterChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(isOn ? Theme.accent : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(isOn ? Color.white : Theme.ink)
        }
        .buttonStyle(.plain)
    }
}
