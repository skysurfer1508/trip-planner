import SwiftUI
import SwiftData
import MapKit

/// Popular places around the destination, ranked by OpenTripMap and Tripadvisor data.
struct DiscoverView: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @Environment(\.modelContext) private var context
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
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var saveFeedback = 0

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
                EmptyState(title: "No destination yet", systemImage: "mappin.slash",
                           message: "Edit the trip and pick a destination to see what's worth visiting.")
            } else {
                content
            }
        }
        .background(Theme.background)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if targetDay != nil {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search places")
                }
                if !days.isEmpty {
                    Menu {
                        Picker("Add to", selection: $targetIndex) {
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                Text("Day \(index + 1) · \(Format.dayChip(day.date))").tag(index)
                            }
                        }
                    } label: {
                        Label("Add to Day \(min(targetIndex, days.count - 1) + 1)", systemImage: "calendar.badge.plus")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            if let day = targetDay {
                AddPlaceView(day: day)
            }
        }
        .sheet(item: $selected) { place in
            SuggestionDetailView(place: place,
                                 trip: trip,
                                 day: targetDay,
                                 isSaved: isSaved(place),
                                 onAdd: { add(place) },
                                 onSave: { save(place) })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sensoryFeedback(.success, trigger: saveFeedback)
        .task(id: loadKey) { await load() }
    }

    private var targetDay: Day? {
        days.indices.contains(targetIndex) ? days[targetIndex] : days.first
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.m) {
                if !secrets.hasOpenTripMap && !secrets.hasTripadvisor {
                    Banner(kind: .info, title: "Rank places by popularity",
                           message: "These are plain Apple Maps results. Add a free OpenTripMap key (and optionally Tripadvisor) to see the most popular and best-rated places first.") {
                        Button("Add API keys") { showSettings = true }
                            .buttonStyle(.primary(fullWidth: false))
                            .padding(.top, Spacing.xs)
                    }
                }
                ForEach(result.notices, id: \.self) { notice in
                    Banner(kind: .warning, title: notice)
                }

                if isLoading && result.places.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SuggestionSkeleton()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Finding places")
                } else if !isLoading && result.places.isEmpty && result.notices.isEmpty {
                    EmptyState(title: "Nothing found", systemImage: "binoculars",
                               message: "Try a bigger radius or another category.")
                } else {
                    ForEach(sortedPlaces) { place in
                        Button {
                            selected = place
                        } label: {
                            SuggestionRow(place: place,
                                          isAdded: addedIDs.contains(place.id),
                                          isSaved: isSaved(place),
                                          onAdd: { add(place) },
                                          onSave: { save(place) })
                        }
                        .buttonStyle(.plain)
                    }
                }

                if result.places.contains(where: { $0.rating != nil }) {
                    Text("Ratings by Tripadvisor")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
            .motion(Motion.fade, value: result.places.count)
        }
        .safeAreaInset(edge: .top, spacing: 0) { controls }
    }

    /// Category chips, then how to sort and how far to look. Stays at the top while the list scrolls.
    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(DiscoverKind.allCases) { k in
                        SelectableChip(title: k.title, symbol: k.symbol, isOn: kind == k) { kind = k }
                    }
                }
                .padding(.horizontal, Spacing.l)
            }
            HStack(spacing: Spacing.m) {
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
                .tint(Theme.accent)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, Spacing.l)
        }
        .padding(.bottom, Spacing.xs)
        .background(Theme.background)
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

    private func isSaved(_ place: SuggestedPlace) -> Bool {
        trip.savedPlaces.contains { $0.name == place.name }
    }

    private func save(_ place: SuggestedPlace) {
        guard !isSaved(place) else { return }
        let saved = SavedPlace(name: place.name,
                               latitude: place.coordinate.latitude,
                               longitude: place.coordinate.longitude,
                               address: place.address ?? "",
                               category: place.kind.stopCategory)
        context.insert(saved)
        saved.trip = trip
        saveFeedback += 1
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

/// A place as a card: its category tile, name, rating, distance and what makes it stand out, with
/// Save and Add as separate 44 pt buttons. (Suggestions carry no photo, so the tile shows the
/// category glyph.)
private struct SuggestionRow: View {
    let place: SuggestedPlace
    let isAdded: Bool
    let isSaved: Bool
    let onAdd: () -> Void
    let onSave: () -> Void

    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 72

    var body: some View {
        let category = place.kind.stopCategory

        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: place.kind.symbol)
                .font(.title2)
                .foregroundStyle(Theme.category(category))
                .frame(width: tile, height: tile)
                .background(Theme.category(category).opacity(0.14), in: Radius.shape(Radius.small))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(place.name)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Spacing.s) {
                    if let rating = place.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(Theme.warning)
                        if let reviews = place.reviews {
                            Text("(\(reviews.formatted()))")
                        }
                    }
                    Label(Format.distance(place.distance), systemImage: "location")
                }
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
                if let rate = place.otmRate, rate >= 3 {
                    Label(rate == 7 ? "Heritage" : "Top rated", systemImage: "rosette")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent)
                }
                if let ranking = place.ranking {
                    Text(ranking)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                Button(action: onSave) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: isSaved)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
                .accessibilityLabel(isSaved ? "Saved" : "Save \(place.name) for later")

                Button(action: onAdd) {
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title2)
                        .foregroundStyle(isAdded ? Theme.success : Theme.accent)
                        .symbolEffect(.bounce, value: isAdded)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAdded)
                .accessibilityLabel(isAdded ? "Added" : "Add \(place.name) to the plan")
            }
        }
        .card(padding: Spacing.m)
        .contentShape(Radius.shape(Radius.card))
    }
}

/// Placeholder card while places load.
private struct SuggestionSkeleton: View {
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SkeletonView(height: tile, width: tile)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonView(height: 18)
                SkeletonView(height: 12, width: 140)
                SkeletonView(height: 12, width: 90)
            }
        }
        .card(padding: Spacing.m)
    }
}
