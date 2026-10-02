import SwiftUI
import MapKit

struct HungryView: View {
    let day: Day
    let origin: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @State private var model = HungryViewModel()
    @State private var addedIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                    .padding(.bottom, 8)
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
            .task(id: model.searchKey) {
                await model.search(origin: origin)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All", isOn: model.cuisine == nil) {
                        model.cuisine = nil
                    }
                    ForEach(Cuisine.allCases) { cuisine in
                        FilterChip(title: cuisine.title, isOn: model.cuisine == cuisine) {
                            model.cuisine = model.cuisine == cuisine ? nil : cuisine
                        }
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                FilterChip(title: "Takeaway", symbol: "bag.fill", isOn: model.takeaway) {
                    model.takeaway.toggle()
                }
                FilterChip(title: "Vegetarian", symbol: "leaf.fill", isOn: model.vegetarian) {
                    model.vegetarian.toggle()
                }
                Spacer()
                Picker("Distance", selection: $model.radius) {
                    ForEach(SearchRadius.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
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
                                   description: Text("Check your connection and try again."))
        } else if model.results.isEmpty {
            ContentUnavailableView("Nothing found", systemImage: "fork.knife",
                                   description: Text("Try a bigger distance or fewer filters."))
        } else {
            List(model.results) { result in
                ResultRow(result: result, isAdded: addedIDs.contains(result.id)) {
                    day.append(Stop.from(result.item))
                    addedIDs.insert(result.id)
                } onNavigate: {
                    RoutingService.openInMaps(name: result.name,
                                              coordinate: result.item.placemark.coordinate,
                                              mode: .walk)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                    Text("\(result.walkMinutes) min · \(Format.distance(result.distance))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let address = result.item.placemark.title {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onNavigate) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(isAdded)
        }
        .padding(.vertical, 2)
    }
}
