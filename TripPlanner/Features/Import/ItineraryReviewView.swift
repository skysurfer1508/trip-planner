import SwiftUI
import MapKit

/// Review screen shared by "Import program" and "AI trip planner": untick, rename, re-match and
/// choose the day, then add the stops to the trip.
struct ItineraryReviewView: View {
    let trip: Trip
    @Bindable var draft: ImportDraft
    var notice: String?
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
                    ForEach($day.stops) { $stop in
                        DraftStopRow(stop: $stop) {
                            pickerTarget = PickerTarget(dayID: day.id, stopID: stop.id, query: stop.title)
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

    private func apply(_ item: MKMapItem, to target: PickerTarget) {
        guard let dayIndex = draft.days.firstIndex(where: { $0.id == target.dayID }),
              let stopIndex = draft.days[dayIndex].stops.firstIndex(where: { $0.id == target.stopID }) else { return }
        draft.days[dayIndex].stops[stopIndex].item = item
        draft.days[dayIndex].stops[stopIndex].include = true
    }

    private func commit() {
        let tripDays = trip.sortedDays
        guard !tripDays.isEmpty else { return }
        let calendar = Calendar.current

        for draftDay in draft.days {
            let day = tripDays[min(max(draftDay.targetIndex, 0), tripDays.count - 1)]
            for draftStop in draftDay.stops where draftStop.include {
                guard let item = draftStop.item else { continue }
                let stop = Stop.from(item)
                if item.pointOfInterestCategory == nil {
                    stop.category = draftStop.category
                }
                if let hour = draftStop.hour {
                    stop.plannedTime = calendar.date(bySettingHour: hour, minute: draftStop.minute ?? 0, second: 0, of: day.date)
                }
                stop.notes = draftStop.notes
                day.append(stop)
            }
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
                } else {
                    Label("No match found", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            Button(action: onChangePlace) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
    }
}
