import SwiftUI
import MapKit

struct AddPlaceView: View {
    let day: Day

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var region: MKCoordinateRegion?
    @State private var addedKeys: Set<String> = []
    @State private var failed = false

    private func key(_ item: MKMapItem) -> String {
        let c = item.placemark.coordinate
        return "\(item.name ?? "")-\(c.latitude)-\(c.longitude)"
    }

    /// True when the day already has this place (same name, within 100 m).
    private func isInPlan(_ item: MKMapItem) -> Bool {
        let name = (item.name ?? "").lowercased()
        return day.stops.contains { stop in
            stop.name.lowercased() == name
                && RoutingService.straightLine(from: stop.coordinate, to: item.placemark.coordinate) < 100
        }
    }

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                let added = addedKeys.contains(key(item)) || isInPlan(item)
                Button {
                    add(item)
                } label: {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: StopCategory(poi: item.pointOfInterestCategory).symbol)
                            .frame(width: 28)
                            .foregroundStyle(StopCategory(poi: item.pointOfInterestCategory).color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Place")
                                .foregroundStyle(.primary)
                            if let address = item.placemark.title {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(added ? Theme.success : Theme.accent)
                    }
                }
                .disabled(added)
            }
            .overlay {
                if results.isEmpty {
                    if failed {
                        ContentUnavailableView("Search failed", systemImage: "wifi.slash",
                                               description: Text("Check your connection and try again."))
                    } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Find a place", systemImage: "magnifyingglass",
                                               description: Text("Search for sights, restaurants, hotels…"))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Add to \(Format.dayChip(day.date))")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let stored = day.trip?.searchRegion {
                    region = stored
                } else {
                    region = await PlaceSearchService.region(for: day.trip?.destination ?? "")
                }
            }
            .task(id: query) {
                await runSearch()
            }
        }
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            failed = false
            return
        }
        // Debounce: the task is cancelled when the text changes again.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        do {
            results = try await PlaceSearchService.search(query: text, region: region)
            failed = false
        } catch {
            if Task.isCancelled { return }
            results = []
            failed = (error as? MKError)?.code != .placemarkNotFound
        }
    }

    private func add(_ item: MKMapItem) {
        day.append(Stop.from(item))
        addedKeys.insert(key(item))
    }
}
