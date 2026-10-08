import SwiftUI
import MapKit

/// Find the place you are staying so the app knows where to start each day from. This is a search
/// only: you book on whatever site you like, then pick the place here. Works for hotels, hostels,
/// apartments and plain addresses.
struct HotelSearchView: View {
    let trip: Trip
    var initialQuery = ""
    let onPick: (HotelResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    @State private var query = ""
    @State private var found: [HotelResult] = []
    @State private var nearby: [HotelResult] = []
    @State private var rated: [HotelResult] = []
    @State private var sort: HotelSort = .bestMatch
    @State private var isSearching = false
    @State private var searched = false

    private var center: CLLocationCoordinate2D? { trip.destinationCoordinate }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBrowsing: Bool { trimmedQuery.isEmpty }

    /// What the list shows: search results, or hotels near the destination.
    private var shown: [HotelResult] {
        let base = isBrowsing ? HotelSearchService.merge(nearby, with: rated) : found
        return HotelSearchService.sorted(base, by: effectiveSort, query: trimmedQuery)
    }

    private var effectiveSort: HotelSort {
        if sort == .topRated && !secrets.hasTripadvisor { return .bestMatch }
        if isBrowsing && sort == .bestMatch { return .closest }
        return sort
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sort) {
                        Text("Best match").tag(HotelSort.bestMatch)
                        Text("Closest").tag(HotelSort.closest)
                        if secrets.hasTripadvisor {
                            Text("Top rated").tag(HotelSort.topRated)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                Section {
                    ForEach(shown) { hotel in
                        Button {
                            onPick(hotel)
                            dismiss()
                        } label: {
                            HotelRow(hotel: hotel)
                        }
                        .buttonStyle(.plain)
                    }

                    if !isBrowsing {
                        Button {
                            onPick(HotelResult(id: "manual", name: trimmedQuery, address: "", coordinate: nil,
                                               distanceFromCenter: nil, phone: nil, website: nil, isLodging: true))
                            dismiss()
                        } label: {
                            Label("Use \"\(trimmedQuery)\" as the name without a location", systemImage: "pencil")
                        }
                    }
                } header: {
                    if isBrowsing, !shown.isEmpty {
                        Text("Hotels near \(trip.destination.isEmpty ? "the destination" : trip.destination)")
                            .textCase(nil)
                    }
                } footer: {
                    footer
                }
            }
            .overlay {
                if isSearching && shown.isEmpty {
                    ProgressView("Searching…")
                } else if !isBrowsing && searched && !isSearching && found.isEmpty {
                    ContentUnavailableView {
                        Label("No match", systemImage: "bed.double")
                    } description: {
                        Text("Try the street, the city or a shorter name. For private rentals, search the address from your booking.")
                    }
                } else if isBrowsing && !isSearching && shown.isEmpty {
                    ContentUnavailableView("Search for your stay", systemImage: "magnifyingglass",
                                           description: Text("Type the hotel's name or the address from your booking."))
                }
            }
            .navigationTitle("Where are you staying?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Hotel name or address")
            .onSubmit(of: .search) {
                Task { await searchTripadvisor() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if query.isEmpty { query = initialQuery }
            }
            .task(id: query) { await runSearch() }
            .task { await loadNearby() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("This only finds the place so your days can start from it. Book wherever you like.")
            if shown.contains(where: { $0.hasTripadvisorData }) {
                Text("Ratings by Tripadvisor")
            }
            if !secrets.hasTripadvisor {
                Text("Add a Tripadvisor key in Settings to see ratings here.")
            }
        }
        .font(.caption)
    }

    // MARK: Searching

    private func runSearch() async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            found = []
            searched = false
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }

        let results = await HotelSearchService.search(query: text, region: searchRegion, center: center)
        if Task.isCancelled { return }

        // Ratings already loaded for this city carry over to matching results.
        found = HotelSearchService.enrich(results, with: rated)
        searched = true
        isSearching = false
    }

    /// Hotels around the destination, with Tripadvisor ratings when a key is set.
    private func loadNearby() async {
        guard let center else { return }
        isSearching = true
        nearby = await HotelSearchService.nearby(center: center, radius: 8_000)
        isSearching = false
        if secrets.hasTripadvisor {
            rated = await HotelSearchService.tripadvisorNearby(center: center, key: secrets.keys.tripadvisor)
        }
    }

    /// Pressing search also asks Tripadvisor for that name (a few calls, so not on every key press).
    private func searchTripadvisor() async {
        guard secrets.hasTripadvisor, !trimmedQuery.isEmpty else { return }
        let extra = await HotelSearchService.tripadvisorSearch(query: trimmedQuery, near: center,
                                                               key: secrets.keys.tripadvisor)
        found = HotelSearchService.merge(HotelSearchService.enrich(found, with: extra), with: extra)
        rated = HotelSearchService.merge(rated, with: extra)
    }

    /// A wider area than for places, so a hotel just outside the centre is still found.
    private var searchRegion: MKCoordinateRegion? {
        guard let center else { return nil }
        return MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    }
}

private struct HotelRow: View {
    let hotel: HotelResult

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: hotel.isLodging ? "bed.double.fill" : "mappin.and.ellipse")
                .font(.title3)
                .frame(width: 34)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(hotel.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !hotel.address.isEmpty {
                    Text(hotel.address)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: Spacing.s) {
                    if !hotel.isLodging {
                        Text("Address")
                            .font(.caption2.bold())
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, 2)
                            .background(Theme.inkSecondary.opacity(0.15), in: Capsule())
                    }
                    if let rating = hotel.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(Theme.warning)
                        if let reviews = hotel.reviews {
                            Text("(\(reviews.formatted()))")
                        }
                    }
                    if let price = hotel.priceLevel {
                        Text(price)
                    }
                    if let distance = hotel.distanceFromCenter {
                        Text("\(Format.distance(distance)) from centre")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                if let ranking = hotel.ranking {
                    Text(ranking)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: Spacing.m) {
                    if hotel.phone != nil {
                        Label("Phone", systemImage: "phone.fill")
                    }
                    if hotel.website != nil {
                        Label("Website", systemImage: "safari")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
