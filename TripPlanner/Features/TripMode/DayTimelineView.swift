import SwiftUI

/// Vertical timeline of a day with a checkbox per stop.
struct DayTimelineView: View {
    let stops: [Stop]
    var onSelect: (Stop) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today's plan")
                .font(.headline)
                .padding(.bottom, Spacing.s)

            if stops.isEmpty {
                Text("Nothing planned for this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                HStack(alignment: .top, spacing: Spacing.m) {
                    Button {
                        stop.isDone.toggle()
                    } label: {
                        Image(systemName: stop.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(stop.isDone ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelect(stop)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name)
                                .strikethrough(stop.isDone)
                                .foregroundStyle(stop.isDone ? .secondary : .primary)
                            HStack(spacing: Spacing.s) {
                                Image(systemName: stop.category.symbol)
                                if let time = stop.plannedTime {
                                    Text(Format.time(time))
                                }
                                Text(Format.minutes(stop.durationMinutes))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, Spacing.s)

                if index < stops.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: Radius.shape(Radius.card))
    }
}
