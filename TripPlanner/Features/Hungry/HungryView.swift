import SwiftUI
import MapKit

struct HungryView: View {
    let day: Day
    let origin: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets
    @State private var model = HungryViewModel()
    @State private var addedIDs: Set<UUID> = []

    private var taskKey: String {
        "\(model.searchKey)-\(secrets.hasTripadvisor)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                    .padding(.bottom, Spacing.s)
                Divider()
                resultList
            }
            .navigationTitle("Hungry?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: taskKey) {
                await model.search(origin: origin, tripadvisorKey: secrets.keys.tripadvisor)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if secrets.hasTripadvisor {
                Picker("Source", selection: $model.source) {
                    ForEach(HungrySource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    SelectableChip(title: "All", isOn: model.cuisine == nil) {
                        model.cuisine = nil
                    }
                    ForEach(Cuisine.allCases) { cuisine in
                        SelectableChip(title: cuisine.title, isOn: model.cuisine == cuisine) {
                            model.cuisine = model.cuisine == cuisine ? nil : cuisine
                        }
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: Spacing.s) {
                if model.source == .nearby || !secrets.hasTripadvisor {
                    SelectableChip(title: "Takeaway", symbol: "bag.fill", isOn: model.takeaway) {
                        model.takeaway.toggle()
                    }
                    SelectableChip(title: "Vegetarian", symbol: "leaf.fill", isOn: model.vegetarian) {
                        model.vegetarian.toggle()
                    }
                }
                Spacer()
                Picker("Distance", selection: $model.radius) {
                    ForEach(SearchRadius.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
        }
        .padding(.top, Spacing.s)
    }

    // MARK: Results

    @ViewBuilder
    private var resultList: some View {
        if origin == nil {
            ContentUnavailableView("No location yet", systemImage: "location.slash",
                                   description: Text("Allow location access, or add a stop to this day so there's a starting point."))
        } else if model.isLoading && model.results.isEmpty {
            ProgressView("Looking around…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.failed {
            ContentUnavailableView("Search failed", systemImage: "wifi.slash",
                                   description: Text(model.errorMessage ?? "Check your connection and try again."))
        } else if model.results.isEmpty {
            ContentUnavailableView("Nothing found", systemImage: "fork.knife",
                                   description: Text("Try a bigger distance or fewer filters."))
        } else {
            List {
                ForEach(model.results) { result in
                    ResultRow(result: result, isAdded: addedIDs.contains(result.id)) {
                        let stop = Stop(name: result.name,
                                        latitude: result.coordinate.latitude,
                                        longitude: result.coordinate.longitude,
                                        address: result.address,
                                        category: result.category)
                        day.append(stop)
                        addedIDs.insert(result.id)
                    } onNavigate: {
                        RoutingService.openInMaps(name: result.name, coordinate: result.coordinate, mode: .walk)
                    }
                }
                if model.results.contains(where: { $0.rating != nil }) {
                    Text("Ratings by Tripadvisor")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSecondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct ResultRow: View {
    let result: HungryResult
    let isAdded: Bool
    let onAdd: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.headline)
                if let rating = result.rating {
                    HStack(spacing: Spacing.s) {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(Theme.warning)
                        if let reviews = result.reviews {
                            Text("(\(reviews.formatted()))")
                        }
                        if !result.cuisines.isEmpty {
                            Text(result.cuisines.prefix(2).joined(separator: ", "))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                }
                HStack(spacing: Spacing.s) {
                    Image(systemName: "figure.walk")
                    Text("\(result.walkMinutes) min · \(Format.distance(result.distance))")
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                if let ranking = result.ranking {
                    Text(ranking)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                } else if !result.address.isEmpty {
                    Text(result.address)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let url = result.url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }
            Button(action: onNavigate) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Theme.success : Theme.accent)
            }
            .buttonStyle(.borderless)
            .disabled(isAdded)
        }
        .padding(.vertical, 2)
    }
}
