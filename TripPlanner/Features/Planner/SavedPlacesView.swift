import SwiftUI
import SwiftData

/// The wishlist: places bookmarked in Discover that aren't on a day yet.
struct SavedPlacesView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private var places: [SavedPlace] {
        trip.savedPlaces.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(places) { place in
                    HStack(spacing: Spacing.m) {
                        Image(systemName: place.category.symbol)
                            .frame(width: 32, height: 32)
                            .background(place.category.color.opacity(0.15), in: Circle())
                            .foregroundStyle(place.category.color)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            if !place.address.isEmpty {
                                Text(place.address)
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()

                        Menu {
                            Section("Move to") {
                                ForEach(Array(trip.sortedDays.enumerated()), id: \.element.persistentModelID) { index, day in
                                    Button("Day \(index + 1) · \(Format.dayChip(day.date))") {
                                        move(place, to: day)
                                    }
                                }
                            }
                            Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                                RoutingService.openInMaps(name: place.name, coordinate: place.coordinate, mode: .walk)
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                        }
                        .accessibilityLabel("Add \(place.name) to a day")
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        context.delete(places[index])
                    }
                }
            }
            .overlay {
                if places.isEmpty {
                    ContentUnavailableView("No saved places", systemImage: "bookmark",
                                           description: Text("Tap the bookmark in Discover to keep ideas here until you know which day they fit."))
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func move(_ place: SavedPlace, to day: Day) {
        let stop = Stop(name: place.name,
                        latitude: place.latitude,
                        longitude: place.longitude,
                        address: place.address,
                        category: place.category)
        day.append(stop)
        context.delete(place)
    }
}
