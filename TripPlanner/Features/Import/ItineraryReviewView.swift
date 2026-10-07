import SwiftUI
import MapKit

/// Review screen shared by "Import program" and "AI trip planner": untick, rename, re-match and
/// choose the day, then add the stops to the trip.
struct ItineraryReviewView: View {
    let trip: Trip
    @Bindable var draft: ImportDraft
    var notice: String?
    /// Runs just before the stops are added (e.g. to clear the days that are being replaced).
    var onBeforeAdd: (() -> Void)?
    /// When set, a "Create again" button builds another version.
    var onRegenerate: (() -> Void)?
    /// When set, a "Walk through" button goes through the plan one day at a time.
    var onWalkThrough: (() -> Void)?
    /// Called after the stops were added.
    var onAdded: () -> Void

    private struct PickerTarget: Identifiable {
        let id = UUID()
        let dayID: UUID
        let stopID: UUID
        let query: String
    }

    @State private var pickerTarget: PickerTarget?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found \(draft.days.reduce(0) { $0 + $1.stops.count }) possible stops")
                        .font(.headline)
                    Text("Untick anything that isn't a place, fix names, and pick the right day. Stops without a matching place can't be added until you choose one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach($draft.days) { $day in
                Section {
                    if let start = startLeg(for: day) {
                        start
                    }
                    ForEach($day.stops) { $stop in
                        VStack(alignment: .leading, spacing: 8) {
                            DraftStopRow(stop: $stop) {
                                pickerTarget = PickerTarget(dayID: day.id, stopID: stop.id, query: stop.title)
                            }
                            if let leg = legAfter(stop, in: day) {
                                leg
                            }
                        }
                    }
                } header: {
                    dayHeader($day)
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add \(draft.includedCount)") { commit() }
                    .disabled(draft.includedCount == 0)
            }
            if onWalkThrough != nil || onRegenerate != nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    if let onWalkThrough {
                        Button("Walk through", systemImage: "figure.walk", action: onWalkThrough)
                    }
                    Spacer()
                    if let onRegenerate {
                        Button("Create again", systemImage: "arrow.triangle.2.circlepath", action: onRegenerate)
                    }
                }
            }
        }
        .sheet(item: $pickerTarget) { target in
            PlacePickerView(query: target.query, region: trip.searchRegion) { item in
                apply(item, to: target)
            }
        }
    }

    private func dayHeader(_ day: Binding<DraftDay>) -> some View {
        HStack {
            Text(day.wrappedValue.label)
                .textCase(nil)
                .font(.subheadline.bold())
            Spacer()
            Picker("Add to", selection: day.targetIndex) {
                ForEach(Array(trip.sortedDays.enumerated()), id: \.offset) { index, tripDay in
                    Text("Day \(index + 1) · \(Format.dayChip(tripDay.date))").tag(index)
                }
            }
            .pickerStyle(.menu)
            .textCase(nil)
        }
    }

    // MARK: Travel between stops

    private var tripDays: [Day] { trip.sortedDays }

    /// The time on the clock at the destination, for timetable lookups.
    private func wallClock(dayIndex: Int, hour: Int?, minute: Int?, plusMinutes extra: Int = 0, fallbackHour: Int = 10) -> Date? {
        guard tripDays.indices.contains(dayIndex) else { return nil }
        let base = hour.map { $0 * 60 + (minute ?? 0) } ?? fallbackHour * 60
        let total = min(base + extra, 23 * 60 + 59)
        return Calendar.current.date(bySettingHour: total / 60, minute: total % 60, second: 0,
                                     of: tripDays[dayIndex].date)
    }

    private func nextStop(after id: UUID, in day: DraftDay) -> DraftStop? {
        guard let index = day.stops.firstIndex(where: { $0.id == id }) else { return nil }
        return day.stops[(index + 1)...].first { $0.include && $0.item != nil }
    }

    /// Travel time from this stop to the next one that will be added, in the preferred way of getting around.
    private func legAfter(_ stop: DraftStop, in day: DraftDay) -> TravelLegView? {
        guard stop.include, let from = stop.item?.placemark.coordinate,
              let next = nextStop(after: stop.id, in: day), let to = next.item?.placemark.coordinate else { return nil }
        return TravelLegView(trip: trip,
                             fromName: stop.item?.name ?? stop.title,
                             toName: next.item?.name ?? next.title,
                             from: from, to: to,
                             departAt: wallClock(dayIndex: day.targetIndex, hour: stop.hour, minute: stop.minute,
                                                 plusMinutes: 60),
                             arriveBy: nil,
                             inset: 52)
    }

    /// Every day starts at the hotel: the way from there to the first stop.
    private func startLeg(for day: DraftDay) -> AnyView? {
        guard tripDays.indices.contains(day.targetIndex),
              let anchor = trip.window(for: tripDays[day.targetIndex].date).anchor,
              let first = day.stops.first(where: { $0.include && $0.item != nil }),
              let to = first.item?.placemark.coordinate else { return nil }
        let name = trip.window(for: tripDays[day.targetIndex].date).anchorName ?? "Hotel"
        let arrive = first.hour == nil ? nil : wallClock(dayIndex: day.targetIndex, hour: first.hour, minute: first.minute)
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    HotelPin()
                    Text("Start from \(name)")
                        .font(.subheadline.weight(.medium))
                }
                TravelLegView(trip: trip, fromName: name, toName: first.item?.name ?? first.title,
                              from: anchor, to: to,
                              departAt: arrive == nil ? wallClock(dayIndex: day.targetIndex, hour: nil, minute: nil, fallbackHour: 9) : nil,
                              arriveBy: arrive, suffix: "to the first stop", inset: 40)
            }
        )
    }

    private func apply(_ item: MKMapItem, to target: PickerTarget) {
        guard let dayIndex = draft.days.firstIndex(where: { $0.id == target.dayID }),
              let stopIndex = draft.days[dayIndex].stops.firstIndex(where: { $0.id == target.stopID }) else { return }
        draft.days[dayIndex].stops[stopIndex].item = item
        draft.days[dayIndex].stops[stopIndex].include = true
    }

    @MainActor
    private func commit() {
        let tripDays = trip.sortedDays
        guard !tripDays.isEmpty else { return }
        let calendar = Calendar.current

        // Build every stop first: stops that were already in the trip are copied before the old
        // ones are removed.
        var created: [(day: Day, stop: Stop, isNew: Bool)] = []
        for draftDay in draft.days {
            let day = tripDays[min(max(draftDay.targetIndex, 0), tripDays.count - 1)]
            for draftStop in draftDay.stops where draftStop.include {
                guard let item = draftStop.item else { continue }
                let stop: Stop
                if let old = draftStop.existing {
                    stop = old.clone()
                } else {
                    stop = Stop.from(item)
                    if item.pointOfInterestCategory == nil {
                        stop.category = draftStop.category
                    }
                    stop.notes = draftStop.notes
                    if stop.address.isEmpty { stop.address = draftStop.address }
                }
                if let hour = draftStop.hour {
                    stop.plannedTime = calendar.date(bySettingHour: hour, minute: draftStop.minute ?? 0, second: 0, of: day.date)
                }
                created.append((day, stop, draftStop.existing == nil))
            }
        }

        onBeforeAdd?()

        for entry in created {
            entry.day.append(entry.stop)
            if entry.isNew {
                PlacePreviewStore.shared.apply(to: entry.stop)
            }
        }
        // Kept bookings (flights, check-in) and the new stops end up in time order.
        for day in Set(created.map { $0.day.persistentModelID }) {
            tripDays.first { $0.persistentModelID == day }?.sortByTime()
        }
        onAdded()
    }
}

private struct DraftStopRow: View {
    @Binding var stop: DraftStop
    let onChangePlace: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Include", isOn: $stop.include)
                .labelsHidden()
                .disabled(stop.item == nil)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: $stop.title)
                    .font(.body)
                if let hour = stop.hour {
                    Text(String(format: "%02d:%02d", hour, stop.minute ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let item = stop.item {
                    Label(item.name.map { "\($0) · \(item.placemark.title ?? "")" } ?? "Matched",
                          systemImage: "mappin.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    PlaceSummaryText(name: item.name ?? stop.title, coordinate: item.placemark.coordinate)
                } else {
                    Label("No match found", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            if let item = stop.item {
                PlaceThumbnail(name: item.name ?? stop.title, coordinate: item.placemark.coordinate,
                               category: stop.category, size: 52)
            }

            Button(action: onChangePlace) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
        .modifier(PreviewLoader(stop: stop))
    }
}

/// Loads the photo and description of a matched place.
private struct PreviewLoader: ViewModifier {
    let stop: DraftStop

    func body(content: Content) -> some View {
        if let item = stop.item {
            content.loadsPlacePreview(name: item.name ?? stop.title,
                                      coordinate: item.placemark.coordinate,
                                      category: stop.category)
        } else {
            content
        }
    }
}
