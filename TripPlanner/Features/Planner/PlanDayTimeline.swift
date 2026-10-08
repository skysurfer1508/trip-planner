import SwiftUI
import SwiftData
import CoreLocation
import UniformTypeIdentifiers

/// One day as a vertical timeline: a continuous line in the day's colour with a numbered pin per stop,
/// the planned time and duration on the left, and the stop on the right as a card. The way to the next
/// stop (walk, transit, drive) sits between the cards as a connector.
///
/// Reorder by pressing and holding a card, then dropping it on another one. Without dragging (VoiceOver,
/// Switch Control) every card has Move up and Move down actions. Tapping a card selects it, which
/// highlights its pin on the map, and opens its details.
struct PlanDayTimeline: View {
    let trip: Trip
    @Bindable var day: Day
    let dayIndex: Int
    @Binding var selected: Stop?
    var onOpen: (Stop) -> Void
    var onAddPlace: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var orderChanged = false
    @State private var showTimes = false
    @State private var dragging: Stop?
    @State private var dropTarget: PersistentIdentifier?

    @ScaledMetric(relativeTo: .body) private var timeWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var railWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 64

    private var compactLayout: Bool { typeSize.isAccessibilitySize }

    private struct OtherDay: Identifiable {
        let number: Int
        let day: Day
        var id: PersistentIdentifier { day.persistentModelID }
    }

    /// The trip's other days, numbered by their position in the trip.
    private var otherDays: [OtherDay] {
        let all = trip.sortedDays
        return all.enumerated()
            .filter { $0.element.persistentModelID != day.persistentModelID }
            .map { OtherDay(number: $0.offset + 1, day: $0.element) }
    }

    var body: some View {
        let stops = day.sortedStops
        let window = trip.window(for: day.date)

        VStack(alignment: .leading, spacing: Spacing.l) {
            header(stops: stops, window: window)

            if stops.isEmpty {
                EmptyState(title: "No stops yet", systemImage: "mappin.slash",
                           message: "Add places, import a program, or pick from Discover.",
                           actionTitle: "Add place", action: onAddPlace)
            } else {
                VStack(spacing: 0) {
                    if let anchor = window.anchor, let first = stops.first {
                        hotelRow(name: window.anchorName ?? "Hotel", from: anchor, first: first)
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                        stopRow(stop, index: index, stops: stops, window: window)
                            .id(stop.persistentModelID)
                    }
                }
                .motion(Motion.state, value: stops.map(\.persistentModelID))

                Button {
                    onAddPlace()
                } label: {
                    Label("Add place", systemImage: "plus")
                }
                .buttonStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .sheet(isPresented: $showTimes, onDismiss: { orderChanged = false }) {
            AutoTimeSheet(day: day)
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(stops: [Stop], window: DayWindow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if !stops.isEmpty {
                summary(stops, start: window.anchor)
            }

            if orderChanged && stops.count > 1 {
                Banner(kind: .info, title: "You changed the order", message: "The times may not fit anymore.") {
                    HStack(spacing: Spacing.s) {
                        Button("Adjust times") { showTimes = true }
                            .buttonStyle(.primary(fullWidth: false))
                        Button("Dismiss") { orderChanged = false }
                            .buttonStyle(.secondary(fullWidth: false))
                    }
                    .padding(.top, Spacing.xs)
                }
            }

            if !window.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Travel").eyebrow()
                    ForEach(window.items) { item in
                        InfoRow(symbol: item.symbol, title: item.text, detail: TripLogistics.timeText(item.minute))
                    }
                }
                .card(padding: Spacing.m)
            }

            WeatherChip(date: day.date,
                        coordinate: stops.first?.coordinate ?? trip.anyCoordinate,
                        outdoorStops: stops.filter { $0.category.isOutdoor }.count)

            DayAlertsView(trip: trip, day: day)
        }
    }

    private func summary(_ stops: [Stop], start: CLLocationCoordinate2D?) -> some View {
        let stay = stops.reduce(0) { $0 + $1.durationMinutes }
        let path = (start.map { [$0] } ?? []) + stops.map(\.coordinate)
        let route = RouteOptimizer.length(path) * 1.25
        let cost = stops.reduce(0) { $0 + $1.estimatedCost }

        let layout = compactLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Spacing.m))

        return layout {
            Label("\(stops.count) \(stops.count == 1 ? "stop" : "stops")", systemImage: "mappin")
            Label(Format.minutes(stay), systemImage: "clock")
            if path.count > 1 {
                Label(Format.distance(route), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            if cost > 0 {
                Label(cost.formatted(.number.precision(.fractionLength(0))), systemImage: "creditcard")
            }
        }
        .font(Typography.label)
        .foregroundStyle(Theme.inkSecondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: Rows

    /// Every day starts from the hotel: the first row shows the way to the first stop.
    private func hotelRow(name: String, from: CLLocationCoordinate2D, first: Stop) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if !compactLayout {
                Color.clear.frame(width: min(timeWidth, 96))
            }
            rail(Pin(kind: .hotel), showLine: true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Start from \(name)")
                    .font(Typography.label)
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 34, alignment: .leading)
                TravelLegView(trip: trip, fromName: name, toName: first.name, from: from, to: first.coordinate,
                              departAt: nil,
                              arriveBy: first.plannedTime.map { day.combine(time: $0) },
                              suffix: "to the first stop", inset: 0)
            }
            .padding(.bottom, Spacing.m)
        }
        .accessibilityElement(children: .contain)
    }

    private func stopRow(_ stop: Stop, index: Int, stops: [Stop], window: DayWindow) -> some View {
        let isLast = index == stops.count - 1
        let isSelected = selected?.persistentModelID == stop.persistentModelID

        return HStack(alignment: .top, spacing: Spacing.s) {
            if !compactLayout {
                timeColumn(stop)
            }
            rail(Pin(kind: .stop(number: index + 1, day: dayIndex), category: stop.category,
                     isSelected: isSelected, isDone: stop.isDone),
                 showLine: !isLast)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                card(stop, number: index + 1, isSelected: isSelected, warnings: warnings(for: stop, window: window))
                if !isLast {
                    let next = stops[index + 1]
                    TravelLegView(trip: trip, fromName: stop.name, toName: next.name,
                                  from: stop.coordinate, to: next.coordinate,
                                  departAt: departure(after: stop), arriveBy: nil, inset: 0)
                        .padding(.vertical, Spacing.xs)
                }
            }
            .padding(.bottom, Spacing.s)
        }
    }

    private func timeColumn(_ stop: Stop) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(stop.plannedTime.map { Format.time($0) } ?? "–")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(Format.minutes(stop.durationMinutes))
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(width: min(timeWidth, 96), alignment: .trailing)
        .padding(.top, Spacing.xs)
        .accessibilityHidden(true)
    }

    /// The pin with the day-coloured line running down from it to the next row.
    private func rail<P: View>(_ pin: P, showLine: Bool) -> some View {
        VStack(spacing: 0) {
            pin
                .padding(.vertical, 2)
            if showLine {
                Rectangle()
                    .fill(Theme.day(dayIndex))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: min(railWidth, 64))
    }

    private func card(_ stop: Stop, number: Int, isSelected: Bool, warnings: [String]) -> some View {
        let timeText = stop.plannedTime.map { Format.time($0) }
        let isDropTarget = dropTarget == stop.persistentModelID

        return Button {
            selected = stop
            onOpen(stop)
        } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if compactLayout {
                        Text([timeText, Format.minutes(stop.durationMinutes)].compactMap { $0 }.joined(separator: " · "))
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Text(stop.name)
                        .font(Typography.headline)
                        .strikethrough(stop.isDone)
                        .foregroundStyle(stop.isDone ? Theme.inkSecondary : Theme.ink)
                        .multilineTextAlignment(.leading)
                    Label(stop.category.title, systemImage: stop.category.symbol)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.category(stop.category))
                    if !stop.summary.isEmpty {
                        Text(stop.summary)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if warnings.isEmpty, hoursAreKnownAndFit(stop) {
                        Label("Open at your time", systemImage: "checkmark.circle")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.warning)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StopThumbnail(stop: stop, size: thumbSize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(Theme.surface, in: Radius.shape(Radius.card))
            .overlay(Radius.shape(Radius.card)
                .strokeBorder(isSelected ? Theme.accent : Theme.separator, lineWidth: isSelected ? 2 : 0.5))
            .contentShape(Radius.shape(Radius.card))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule().fill(Theme.accent).frame(height: 4).offset(y: -Spacing.xs - 2)
            }
        }
        .onDrag {
            dragging = stop
            Haptics.impact(.light)
            return NSItemProvider(object: stop.name as NSString)
        }
        .onDrop(of: [UTType.plainText],
                delegate: StopDropDelegate(target: stop, dragging: $dragging, dropTarget: $dropTarget) { dragged, target in
                    drop(dragged, onto: target)
                })
        .contextMenu {
            Menu("Move to day", systemImage: "arrow.right.circle") {
                ForEach(otherDays) { entry in
                    Button("Day \(entry.number) · \(Format.dayChip(entry.day.date))") {
                        Motion.perform { day.move(stop, to: entry.day) }
                    }
                }
            }
            .disabled(otherDays.isEmpty)
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Motion.perform { day.duplicate(stop) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                Haptics.warning()
                Motion.perform { day.remove(stop) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(stop, number: number, timeText: timeText, warnings: warnings))
        .accessibilityHint("Opens the details")
        .accessibilityAction(named: "Move up") { move(stop, by: -1) }
        .accessibilityAction(named: "Move down") { move(stop, by: 1) }
        .task {
            await PlaceInfoLoader.ensureInfo(for: stop)
            await OpeningHoursLoader.ensureHours(for: stop)
        }
    }

    private func accessibilityLabel(_ stop: Stop, number: Int, timeText: String?, warnings: [String]) -> String {
        var parts = ["Stop \(number)", stop.name, stop.category.title]
        if let timeText { parts.append("at \(timeText)") }
        parts.append(Format.minutes(stop.durationMinutes))
        if stop.isDone { parts.append("done") }
        parts += warnings
        return parts.joined(separator: ", ")
    }

    // MARK: Reordering

    private func drop(_ dragged: Stop, onto target: Stop) {
        var ordered = day.sortedStops
        guard let from = ordered.firstIndex(where: { $0.persistentModelID == dragged.persistentModelID }),
              let to = ordered.firstIndex(where: { $0.persistentModelID == target.persistentModelID }),
              from != to else { return }
        Haptics.impact(.medium)
        Motion.perform {
            ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            day.renumber(ordered)
            orderChanged = true
        }
    }

    private func move(_ stop: Stop, by offset: Int) {
        var ordered = day.sortedStops
        guard let from = ordered.firstIndex(where: { $0.persistentModelID == stop.persistentModelID }) else { return }
        let to = from + offset
        guard ordered.indices.contains(to) else { return }
        Haptics.select()
        Motion.perform {
            ordered.swapAt(from, to)
            day.renumber(ordered)
            orderChanged = true
        }
    }

    // MARK: Times and warnings

    private func departure(after stop: Stop) -> Date {
        if let time = stop.plannedTime {
            return day.combine(time: time).addingTimeInterval(TimeInterval(stop.durationMinutes * 60))
        }
        return day.defaultWallClock(hour: 10)
    }

    /// Everything that is wrong with a stop's time: flights, and opening hours.
    private func warnings(for stop: Stop, window: DayWindow) -> [String] {
        var result: [String] = []
        if let message = flightWarning(for: stop, window: window) { result.append(message) }
        if let message = hoursWarning(for: stop) { result.append(message) }
        return result
    }

    /// "Closed on Mondays", "Opens at 10:00, after your planned time", from the saved OSM hours.
    private func hoursWarning(for stop: Stop) -> String? {
        guard let planned = stop.plannedTime, !stop.openingHours.isEmpty,
              let hours = OpeningHours.parse(stop.openingHours) else { return nil }
        let verdict = hours.verdict(visitAt: planned, minutes: stop.durationMinutes,
                                    isHoliday: { trip.isNationalHoliday($0) })
        return OpeningHours.warning(for: verdict).map { "\($0) (opening hours)" }
    }

    private func hoursAreKnownAndFit(_ stop: Stop) -> Bool {
        stop.plannedTime != nil && !stop.openingHours.isEmpty && OpeningHours.parse(stop.openingHours) != nil
    }

    /// Why a stop's time doesn't fit the flights, if it doesn't.
    private func flightWarning(for stop: Stop, window: DayWindow) -> String? {
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
}

/// Drops a dragged stop onto the stop it is hovering over and tells the timeline where the line goes.
/// Drop callbacks always arrive on the main thread, so the main-actor work is marked as such.
private struct StopDropDelegate: DropDelegate {
    let target: Stop
    @Binding var dragging: Stop?
    @Binding var dropTarget: PersistentIdentifier?
    let commit: (Stop, Stop) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.persistentModelID != target.persistentModelID else { return }
        dropTarget = target.persistentModelID
        MainActor.assumeIsolated { Haptics.select() }
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target.persistentModelID { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            dropTarget = nil
        }
        guard let dragging, dragging.persistentModelID != target.persistentModelID else { return false }
        MainActor.assumeIsolated { commit(dragging, target) }
        return true
    }
}
