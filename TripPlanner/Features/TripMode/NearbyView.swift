import SwiftUI
import MapKit

/// Quick "what's around me" lookups for the road.
enum NearbyKind: String, CaseIterable, Identifiable {
    case coffee, atm, pharmacy, restroom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coffee: "Coffee"
        case .atm: "ATM"
        case .pharmacy: "Pharmacy"
        case .restroom: "Restrooms"
        }
    }

    var symbol: String {
        switch self {
        case .coffee: "cup.and.saucer.fill"
        case .atm: "banknote.fill"
        case .pharmacy: "cross.case.fill"
        case .restroom: "figure.stand.dress.line.vertical.figure"
        }
    }

    var categories: [MKPointOfInterestCategory] {
        switch self {
        case .coffee: [.cafe, .bakery]
        case .atm: [.atm, .bank]
        case .pharmacy: [.pharmacy]
        case .restroom: [.restroom]
        }
    }

    var stopCategory: StopCategory {
        self == .coffee ? .cafe : .other
    }
}

struct NearbyView: View {
    let kind: NearbyKind
    let origin: CLLocationCoordinate2D?
    let day: Day

    @Environment(\.dismiss) private var dismiss
    @State private var results: [HungryResult] = []
    @State private var isLoading = true
    @State private var addedIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if origin == nil {
                    ContentUnavailableView("No location yet", systemImage: "location.slash",
                                           description: Text("Allow location access to look around."))
                } else if isLoading {
                    ProgressView("Looking around…")
                } else if results.isEmpty {
                    ContentUnavailableView("Nothing within 1.5 km", systemImage: kind.symbol)
                } else {
                    List(results) { result in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name)
                                    .font(.headline)
                                Label("\(result.walkMinutes) min · \(Format.distance(result.distance))",
                                      systemImage: "figure.walk")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                RoutingService.openInMaps(name: result.name, coordinate: result.coordinate, mode: .walk)
                            } label: {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Directions to \(result.name)")

                            Button {
                                let stop = Stop(name: result.name,
                                                latitude: result.coordinate.latitude,
                                                longitude: result.coordinate.longitude,
                                                address: result.address,
                                                category: kind.stopCategory)
                                day.append(stop)
                                addedIDs.insert(result.id)
                            } label: {
                                Image(systemName: addedIDs.contains(result.id) ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(addedIDs.contains(result.id) ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .disabled(addedIDs.contains(result.id))
                            .accessibilityLabel("Add \(result.name) to today")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let origin else {
            isLoading = false
            return
        }
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let items = (try? await PlaceSearchService.nearby(query: nil,
                                                          categories: kind.categories,
                                                          center: origin,
                                                          radius: 1500)) ?? []
        results = items.prefix(20).map { item in
            let c = item.placemark.coordinate
            return HungryResult(name: item.name ?? kind.title,
                                coordinate: c,
                                address: item.placemark.title ?? "",
                                distance: here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
        }
        isLoading = false
    }
}
