import SwiftUI
import SwiftData
import CoreLocation

/// Reorderable list of a day's stops. Reordering needs edit mode (Edit button in the planner).
struct DayStopListView: View {
    @Bindable var day: Day
    var onSelect: (Stop) -> Void

    @Environment(\.modelContext) private var context

    private struct OtherDay: Identifiable {
        let number: Int
        let day: Day
        var id: PersistentIdentifier { day.persistentModelID }
    }

    /// The trip's other days, numbered by their position in the trip.
    private var otherDays: [OtherDay] {
        let all = day.trip?.sortedDays ?? []
        return all.enumerated()
            .filter { $0.element.persistentModelID != day.persistentModelID }
            .map { OtherDay(number: $0.offset + 1, day: $0.element) }
    }

    /// Why a stop's time doesn't fit the flights, if it doesn't.
    private func warning(for stop: Stop, window: DayWindow) -> String? {
        guard let time = stop.plannedTime else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if let ready = window.startMinute, minute < ready {
            return "Before you're ready after landing (\(TripLogistics.timeText(ready)))"
        }
        if let leave = window.endMinute, minute >= leave {
            return "After you have to leave for the airport (\(TripLogistics.timeText(leave)))"
        }
        return nil
    }

    var body: some View {
        let stops = day.sortedStops
        let window = day.trip?.window(for: day.date) ?? DayWindow()

        List {
            if !window.items.isEmpty {
                Section {
                    ForEach(window.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            Text(TripLogistics.timeText(item.minute))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(item.text)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("Travel")
                        .textCase(nil)
                        .font(.caption)
                }
            }

            if stops.isEmpty {
                ContentUnavailableView("No stops yet", systemImage: "mappin.slash",
                                       description: Text("Tap + to add places, import a program, or pick from Discover."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    if let anchor = window.anchor, let first = stops.first {
                        HotelStartRow(name: window.anchorName ?? "Hotel", from: anchor, to: first.coordinate)
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                        Button {
                            onSelect(stop)
                        } label: {
                            StopRow(stop: stop,
                                    number: index + 1,
                                    next: index + 1 < stops.count ? stops[index + 1] : nil,
                                    warning: warning(for: stop, window: window))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Menu("Move to day", systemImage: "arrow.right.circle") {
                                ForEach(otherDays) { entry in
                                    Button("Day \(entry.number) · \(Format.dayChip(entry.day.date))") {
                                        day.move(stop, to: entry.day)
                                    }
                                }
                            }
                            .disabled(otherDays.isEmpty)
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                day.duplicate(stop)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                context.delete(stop)
                                day.renumber(day.sortedStops.filter { $0 !== stop })
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                day.duplicate(stop)
                            }
                            .tint(.indigo)
                        }
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
                } header: {
                    DaySummary(stops: stops, start: window.anchor)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// Every day starts from the hotel: the first row shows the way to the first stop.
private struct HotelStartRow: View {
    let name: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D

    var body: some View {
        let distance = RoutingService.straightLine(from: from, to: to)
        let mode: TravelMode = distance > 2_500 ? .drive : .walk
        let time = RoutingService.estimate(from: from, to: to, mode: mode)

        HStack(spacing: 12) {
            HotelPin()
            VStack(alignment: .leading, spacing: 2) {
                Text("Start from \(name)")
                    .font(.subheadline.weight(.medium))
                Label("\(Format.duration(time)) · \(Format.distance(distance * 1.25)) to the first stop",
                      systemImage: mode.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DaySummary: View {
    let stops: [Stop]
    var start: CLLocationCoordinate2D?

    var body: some View {
        let stay = stops.reduce(0) { $0 + $1.durationMinutes }
        let path = (start.map { [$0] } ?? []) + stops.map(\.coordinate)
        let route = RouteOptimizer.length(path) * 1.25
        let cost = stops.reduce(0) { $0 + $1.estimatedCost }

        HStack(spacing: 10) {
            Label("\(stops.count) \(stops.count == 1 ? "stop" : "stops")", systemImage: "mappin")
            Label(Format.minutes(stay), systemImage: "clock")
            if path.count > 1 {
                Label(Format.distance(route), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            if cost > 0 {
                Label(cost.formatted(.number.precision(.fractionLength(0))), systemImage: "creditcard")
            }
        }
        .font(.caption)
        .textCase(nil)
    }
}

struct StopRow: View {
    let stop: Stop
    let number: Int
    var next: Stop?
    var warning: String?

    private var legMode: TravelMode {
        guard let next else { return .walk }
        return RoutingService.straightLine(from: stop.coordinate, to: next.coordinate) > 2_500 ? .drive : .walk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    if !stop.summary.isEmpty {
                        Text(stop.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 4)
                StopThumbnail(stop: stop, size: 56)
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            }

            if let next {
                let distance = RoutingService.straightLine(from: stop.coordinate, to: next.coordinate)
                let time = RoutingService.estimate(from: stop.coordinate, to: next.coordinate, mode: legMode)
                Label("\(Format.duration(time)) · \(Format.distance(distance * 1.25))", systemImage: legMode.symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 36)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task { await PlaceInfoLoader.ensureInfo(for: stop) }
    }
}
