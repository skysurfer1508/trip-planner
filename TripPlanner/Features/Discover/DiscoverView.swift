import SwiftUI
import MapKit

/// Popular places around the destination, ranked by OpenTripMap and Tripadvisor data.
struct DiscoverView: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @Environment(LocationService.self) private var location

    private enum SortOrder: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case nearest = "Nearest"
        var id: String { rawValue }
    }

    @State private var kind: DiscoverKind = .sights
    @State private var sort: SortOrder = .popular
    @State private var radiusKm = 5.0
    @State private var result = SuggestionResult(places: [], notices: [])
    @State private var isLoading = false
    @State private var targetIndex = 0
    @State private var addedIDs: Set<String> = []
    @State private var selected: SuggestedPlace?

    private var center: CLLocationCoordinate2D? {
        trip.destinationCoordinate ?? location.coordinate ?? trip.anyCoordinate
    }

    private var days: [Day] { trip.sortedDays }

    private var sortedPlaces: [SuggestedPlace] {
        switch sort {
        case .popular: result.places.sorted { $0.score > $1.score }
        case .nearest: result.places.sorted { $0.distance < $1.distance }
        }
    }

    private var loadKey: String {
        let lat = center.map { String(format: "%.2f", $0.latitude) } ?? "-"
        let lon = center.map { String(format: "%.2f", $0.longitude) } ?? "-"
        return "\(kind.rawValue)-\(radiusKm)-\(lat)-\(lon)-\(secrets.hasOpenTripMap)-\(secrets.hasTripadvisor)"
    }

    var body: some View {
        Group {
            if center == nil {
                ContentUnavailableView("No destination yet", systemImage: "mappin.slash",
                                       description: Text("Edit the trip and pick a destination to see what's worth visiting."))
            } else {
                content
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !days.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Add to", selection: $targetIndex) {
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                Text("Day \(index + 1) · \(Format.dayChip(day.date))").tag(index)
                            }
                        }
                    } label: {
                        Label("Add to Day \(min(targetIndex, days.count - 1) + 1)", systemImage: "calendar.badge.plus")
                    }
                }
            }
        }
        .sheet(item: $selected) { place in
            SuggestionDetailView(place: place, trip: trip, day: targetDay) {
                add(place)
            }
        }
        .task(id: loadKey) { await load() }
    }

    private var targetDay: Day? {
        days.indices.contains(targetIndex) ? days[targetIndex] : days.first
    }

    private var content: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiscoverKind.allCases) { k in
                        FilterChip(title: k.title, symbol: k.symbol, isOn: kind == k) { kind = k }
                    }
                }
                .padding(.horizontal)
            }
            HStack {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Radius", selection: $radiusKm) {
                    Text("2 km").tag(2.0)
                    Text("5 km").tag(5.0)
                    Text("10 km").tag(10.0)
                    Text("25 km").tag(25.0)
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        List {
            ForEach(result.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(sortedPlaces) { place in
                Button {
                    selected = place
                } label: {
                    SuggestionRow(place: place, isAdded: addedIDs.contains(place.id)) {
                        add(place)
                    }
                }
                .buttonStyle(.plain)
            }
            if result.places.contains(where: { $0.rating != nil }) {
                Text("Ratings by Tripadvisor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading && result.places.isEmpty {
                ProgressView("Finding places…")
            } else if !isLoading && result.places.isEmpty && result.notices.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "binoculars",
                                       description: Text("Try a bigger radius or another category."))
            }
        }
    }

    private func load() async {
        guard let center else { return }
        isLoading = true
        defer { isLoading = false }
        let loaded = await SuggestionService.load(kind: kind,
                                                  center: center,
                                                  radiusMeters: radiusKm * 1000,
                                                  keys: secrets.keys)
        if Task.isCancelled { return }
        result = loaded
    }

    private func add(_ place: SuggestedPlace) {
        guard let day = targetDay, !addedIDs.contains(place.id) else { return }
        let stop = Stop(name: place.name,
                        latitude: place.coordinate.latitude,
                        longitude: place.coordinate.longitude,
                        address: place.address ?? "",
                        category: place.kind.stopCategory)
        day.append(stop)
        addedIDs.insert(place.id)
    }
}

private struct SuggestionRow: View {
    let place: SuggestedPlace
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.kind.symbol)
                .frame(width: 32, height: 32)
                .background(place.kind.stopCategory.color.opacity(0.15), in: Circle())
                .foregroundStyle(place.kind.stopCategory.color)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let rating = place.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.orange)
                        if let reviews = place.reviews {
                            Text("(\(reviews.formatted()))")
                        }
                    }
                    if let rate = place.otmRate, rate >= 3 {
                        Label(rate == 7 ? "Heritage" : "Top rated", systemImage: "rosette")
                            .foregroundStyle(.tint)
                    }
                    Text(Format.distance(place.distance))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let ranking = place.ranking {
                    Text(ranking)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(isAdded)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
