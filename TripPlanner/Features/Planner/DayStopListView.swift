import SwiftUI
import SwiftData

/// Reorderable list of a day's stops. Reordering needs edit mode (Edit button in the planner).
struct DayStopListView: View {
    @Bindable var day: Day
    var onSelect: (Stop) -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            if day.stops.isEmpty {
                ContentUnavailableView("No stops yet", systemImage: "mappin.slash",
                                       description: Text("Tap + to add places to this day."))
                    .listRowBackground(Color.clear)
            }

            ForEach(Array(day.sortedStops.enumerated()), id: \.element.persistentModelID) { index, stop in
                Button {
                    onSelect(stop)
                } label: {
                    StopRow(stop: stop, number: index + 1)
                }
                .buttonStyle(.plain)
            }
            .onMove { offsets, destination in
                var ordered = day.sortedStops
                ordered.move(fromOffsets: offsets, toOffset: destination)
                day.renumber(ordered)
            }
            .onDelete { offsets in
                var ordered = day.sortedStops
                let removed = offsets.map { ordered[$0] }
                ordered.remove(atOffsets: offsets)
                removed.forEach { context.delete($0) }
                day.renumber(ordered)
            }
        }
        .listStyle(.plain)
    }
}

struct StopRow: View {
    let stop: Stop
    let number: Int

    var body: some View {
        HStack(spacing: 12) {
            StopPin(number: number, category: stop.category, isDone: stop.isDone)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.body)
                    .strikethrough(stop.isDone)
                    .foregroundStyle(stop.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    Image(systemName: stop.category.symbol)
                    if let time = stop.plannedTime {
                        Text(Format.time(time))
                    }
                    Text(Format.minutes(stop.durationMinutes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
