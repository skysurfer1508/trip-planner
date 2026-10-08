import SwiftUI

/// The sticky strip of days at the top of the Plan tab. Each pill shows the weekday, the date and how
/// many stops the day has. The selected day fills with its own colour (the same colour as its pins and
/// route), the others show it as a small bar, so the colour is never the only way to tell days apart.
struct DayStrip: View {
    let days: [Day]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Array(days.enumerated()), id: \.element.persistentModelID) { index, day in
                        pill(index: index, day: day)
                            .id(index)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
            }
            .onChange(of: selectedIndex) { _, index in
                Motion.perform { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                proxy.scrollTo(selectedIndex, anchor: .center)
            }
        }
    }

    private func pill(index: Int, day: Day) -> some View {
        let isSelected = index == selectedIndex
        let count = day.stops.count
        let color = Theme.day(index)
        let weekday = day.date.formatted(.dateTime.weekday(.abbreviated))
        let number = day.date.formatted(.dateTime.day())
        let stopText = "\(count) \(count == 1 ? "stop" : "stops")"

        return Button {
            guard !isSelected else { return }
            Haptics.select()
            Motion.perform(Motion.snappy) { selectedIndex = index }
        } label: {
            VStack(spacing: 2) {
                Text(weekday)
                    .font(Typography.eyebrow)
                    .textCase(.uppercase)
                Text(number)
                    .font(Typography.numeric)
                Text(stopText)
                    .font(Typography.caption)
                Capsule()
                    .fill(isSelected ? Theme.onAccent : color)
                    .frame(width: 20, height: 4)
                    .padding(.top, 2)
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minWidth: 68, minHeight: 44)
            .background(isSelected ? color : Theme.surface, in: Radius.shape(Radius.small))
            .overlay(Radius.shape(Radius.small)
                .strokeBorder(isSelected ? Color.clear : Theme.separator, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day \(index + 1), \(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(stopText)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
