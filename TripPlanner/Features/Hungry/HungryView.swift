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
            EmptyState(title: "No location yet", systemImage: "location.slash",
                       message: "Allow location access, or add a stop to this day so there's a starting point.")
        } else if model.isLoading && model.results.isEmpty {
            VStack(spacing: Spacing.m) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            SkeletonView(height: 18, width: 180)
                            SkeletonView(height: 12, width: 120)
                            SkeletonView(height: 12, width: 90)
                        }
                        Spacer()
                    }
                    .card(padding: Spacing.m)
                }
            }
            .padding(Spacing.l)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Looking around")
        } else if model.failed {
            EmptyState(title: "Search failed", systemImage: "wifi.slash",
                       message: model.errorMessage ?? "Check your connection and try again.")
        } else if model.results.isEmpty {
            EmptyState(title: "Nothing found", systemImage: "fork.knife",
                       message: "Try a bigger distance or fewer filters.")
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
                        Haptics.success()
                    } onNavigate: {
                        RoutingService.openInMaps(name: result.name, coordinate: result.coordinate, mode: .walk)
                    }
                }
                if model.results.contains(where: { $0.rating != nil }) {
                    Text("Ratings by Tripadvisor")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ResultRow: View {
    let result: HungryResult
    let isAdded: Bool
    let onAdd: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(result.name)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.ink)
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
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkSecondary)
                }
                Label("\(result.walkMinutes) min · \(Format.distance(result.distance))", systemImage: "figure.walk")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkSecondary)
                if let ranking = result.ranking {
                    Text(ranking)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                } else if !result.address.isEmpty {
                    Text(result.address)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = result.url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open \(result.name) on Tripadvisor")
            }
            Button(action: onNavigate) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Directions to \(result.name)")
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Theme.success : Theme.accent)
                    .symbolEffect(.bounce, value: isAdded)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .accessibilityLabel(isAdded ? "Added" : "Add \(result.name) to the day")
        }
        .padding(.vertical, Spacing.xs)
    }
}
