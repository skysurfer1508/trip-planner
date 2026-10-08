import SwiftUI

/// A small read-only label (opening hours state, price level, "Open now").
struct Chip: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(title)
        }
        .font(Typography.label)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 0.5))
    }
}

/// A chip you can switch on and off, used for filters, day pickers and option tiles. When it is on
/// it fills with the accent AND shows a checkmark, so the state is not colour-only. The tap area is
/// at least 44 pt tall even though the pill itself is smaller.
struct SelectableChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: Spacing.xs) {
                if isOn {
                    Image(systemName: "checkmark").imageScale(.small)
                } else if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title)
            }
            .font(Typography.label)
            .foregroundStyle(isOn ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(isOn ? Theme.accent : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.separator, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
