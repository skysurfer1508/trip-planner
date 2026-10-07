import SwiftUI
import SwiftData
import CoreLocation

/// Heads-ups for one day: a public holiday (places may be closed) and rain with outdoor plans.
struct DayAlertsView: View {
    @Bindable var trip: Trip
    let day: Day

    @State private var weather: DayWeather?
    @State private var showRain = false

    private var outdoorStops: [Stop] {
        day.sortedStops.filter { $0.setting == .outdoor }
    }

    private var weatherCoordinate: CLLocationCoordinate2D? {
        day.sortedStops.first?.coordinate ?? trip.anyCoordinate
    }

    var body: some View {
        VStack(spacing: 8) {
            if let holiday = trip.holiday(on: day.date) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public holiday: \(holiday.name)\(holiday.isRegional ? " (some regions)" : "")")
                            .font(.subheadline.bold())
                        Text("Many shops, offices and some museums may be closed or have shorter hours.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            if let weather, weather.isWet, !outdoorStops.isEmpty {
                Button {
                    showRain = true
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cloud.rain.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rain likely (\(weather.rainChance)%) and \(outdoorStops.count) outdoor \(outdoorStops.count == 1 ? "stop" : "stops") planned")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("Tap to swap them for indoor places nearby.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: day.persistentModelID) {
            await TripHolidays.ensure(trip)
            if let coordinate = weatherCoordinate {
                weather = await WeatherService.forecast(for: day.date, at: coordinate)
            }
        }
        .sheet(isPresented: $showRain) {
            RainReplanSheet(trip: trip, day: day, weather: weather)
        }
    }
}

/// Proposes an indoor place for every outdoor stop of a rainy day. The outdoor ones go to
/// Saved places, so nothing is lost.
struct RainReplanSheet: View {
    @Bindable var trip: Trip
    let day: Day
    let weather: DayWeather?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Secrets.self) private var secrets

    private struct Row: Identifiable {
        let id = UUID()
        let stop: Stop
        let place: SuggestedPlace
        var selected = true
    }

    @State private var rows: [Row] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if let weather {
                    Section {
                        Label("\(weather.summary) · \(weather.rainChance)% chance of rain", systemImage: weather.symbol)
                            .font(.subheadline)
                    }
                }

                if loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Finding indoor places…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if rows.isEmpty {
                    Section {
                        ContentUnavailableView("No indoor alternatives found", systemImage: "umbrella",
                                               description: Text("Nothing suitable was found near these stops."))
                    }
                } else {
                    Section {
                        ForEach($rows) { $row in
                            Toggle(isOn: $row.selected) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.stop.name)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .strikethrough(row.selected)
                                    Label(row.place.name, systemImage: row.place.kind.symbol)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(Format.distance(RoutingService.straightLine(from: row.stop.coordinate, to: row.place.coordinate))) from the original")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Swap outdoor stops")
                    } footer: {
                        Text("The time and length of each stop stay the same. The outdoor places are kept in Saved places, so you can put them back on a dry day.")
                    }
                }
            }
            .navigationTitle("Plan for rain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Swap \(rows.filter(\.selected).count)") { apply() }
                        .disabled(rows.filter(\.selected).isEmpty)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        let outdoor = day.sortedStops.filter { $0.setting == .outdoor }
        guard !outdoor.isEmpty else {
            loading = false
            return
        }
        let points = day.sortedStops.map(\.coordinate)
        let center = CLLocationCoordinate2D(latitude: points.reduce(0) { $0 + $1.latitude } / Double(points.count),
                                            longitude: points.reduce(0) { $0 + $1.longitude } / Double(points.count))
        let keys = APIKeys(openTripMap: secrets.keys.openTripMap, tripadvisor: "", gemini: "")
        var places: [SuggestedPlace] = []
        for kind in [DiscoverKind.culture, .fun, .sights] {
            let result = await SuggestionService.load(kind: kind, center: center, radiusMeters: 5_000, keys: keys)
            places += result.places
        }

        let inTrip = Set(trip.days.flatMap { $0.stops.map(\.name) })
        let candidates = RainPlanner.indoorCandidates(places, excludingNames: inTrip)
        let proposals = RainPlanner.proposals(
            for: outdoor.map { RainPlanner.OutdoorStop(id: "\($0.persistentModelID.hashValue)", name: $0.name, coordinate: $0.coordinate) },
            candidates: candidates)

        rows = proposals.compactMap { proposal in
            guard let stop = outdoor.first(where: { "\($0.persistentModelID.hashValue)" == proposal.outdoorID }) else { return nil }
            return Row(stop: stop, place: proposal.place)
        }
        loading = false
    }

    private func apply() {
        for row in rows where row.selected {
            let old = row.stop
            let new = Stop(name: row.place.name,
                           latitude: row.place.coordinate.latitude,
                           longitude: row.place.coordinate.longitude,
                           address: row.place.address ?? "",
                           category: .sight)
            context.insert(new)
            day.stops.append(new)
            new.order = old.order
            new.plannedTime = old.plannedTime
            new.durationMinutes = old.durationMinutes

            let saved = SavedPlace(name: old.name, latitude: old.latitude, longitude: old.longitude,
                                   address: old.address, category: old.category)
            context.insert(saved)
            saved.trip = trip
            context.delete(old)
        }
        day.renumber(day.sortedStops)
        dismiss()
    }
}
