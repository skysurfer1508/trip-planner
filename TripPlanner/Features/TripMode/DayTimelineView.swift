import SwiftUI

/// The day's stops with a checkbox each, on Trip Mode. The check has a 44 pt target, bounces when it
/// flips, and the state is the glyph (circle or checkmark) as well as its colour.
struct DayTimelineView: View {
    let stops: [Stop]
    var onSelect: (Stop) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today's plan")
                .font(Typography.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Spacing.s)

            if stops.isEmpty {
                Text("Nothing planned for this day.")
                    .font(Typography.label)
                    .foregroundStyle(Theme.inkSecondary)
            }

            ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                HStack(alignment: .center, spacing: Spacing.s) {
                    Button {
                        Motion.perform(Motion.snappy) { stop.isDone.toggle() }
                    } label: {
                        Image(systemName: stop.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(stop.isDone ? Theme.success : Theme.inkSecondary)
                            .symbolEffect(.bounce, value: stop.isDone)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(stop.isDone ? "Done: \(stop.name)" : "Mark \(stop.name) as done")
                    .accessibilityAddTraits(.isToggle)

                    Button {
                        onSelect(stop)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name)
                                .font(Typography.body)
                                .strikethrough(stop.isDone)
                                .foregroundStyle(stop.isDone ? Theme.inkSecondary : Theme.ink)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: Spacing.s) {
                                Image(systemName: stop.category.symbol)
                                if let time = stop.plannedTime {
                                    Text(Format.time(time))
                                }
                                Text(Format.minutes(stop.durationMinutes))
                            }
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if index < stops.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .card()
    }
}
