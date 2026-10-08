import SwiftUI

/// A compact row of the day's stops: done ones are checked, the next one is enlarged, and the line
/// between two stops fills with the day's colour once the first is done.
struct DayProgressRail: View {
    let stops: [Stop]
    let next: Stop?
    let dayIndex: Int

    var body: some View {
        let done = stops.filter(\.isDone).count

        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("\(done) of \(stops.count) done")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                        Pin(kind: .stop(number: index + 1, day: dayIndex),
                            isSelected: stop.persistentModelID == next?.persistentModelID,
                            isDone: stop.isDone)
                        if index < stops.count - 1 {
                            Rectangle()
                                .fill(stop.isDone ? Theme.day(dayIndex) : Theme.separator)
                                .frame(width: 20, height: 2)
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
                .padding(.horizontal, Spacing.xs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day progress")
        .accessibilityValue("\(done) of \(stops.count) stops done")
    }
}
