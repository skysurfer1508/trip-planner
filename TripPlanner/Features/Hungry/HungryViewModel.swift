import Foundation
import Observation
import MapKit

enum Cuisine: String, CaseIterable, Identifiable {
    case asian, italian, pizza, burger, sushi, indian, mexican, cafe, bakery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asian: "Asian"
        case .italian: "Italian"
        case .pizza: "Pizza"
        case .burger: "Burger"
        case .sushi: "Sushi"
        case .indian: "Indian"
        case .mexican: "Mexican"
        case .cafe: "Café"
        case .bakery: "Bakery"
        }
    }

    var query: String {
        switch self {
        case .cafe: "cafe"
        case .bakery: "bakery"
        default: "\(rawValue) restaurant"
        }
    }
}

enum SearchRadius: Double, CaseIterable, Identifiable {
    case near = 500
    case medium = 1000
    case far = 2000

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .near: "500 m"
        case .medium: "1 km"
        case .far: "2 km"
        }
    }
}

struct HungryResult: Identifiable {
    let id = UUID()
    let item: MKMapItem
    let distance: CLLocationDistance

    var name: String { item.name ?? "Restaurant" }
    var walkMinutes: Int { max(1, Int((distance * 1.25 / TravelMode.walk.fallbackSpeed / 60).rounded())) }
}

@Observable
final class HungryViewModel {
    var cuisine: Cuisine?
    var takeaway = false
    var vegetarian = false
    var radius: SearchRadius = .medium

    var results: [HungryResult] = []
    var isLoading = false
    var failed = false

    /// Changes whenever a filter changes; the view re-runs the search on it.
    var searchKey: String {
        "\(cuisine?.rawValue ?? "all")-\(takeaway)-\(vegetarian)-\(radius.rawValue)"
    }

    private static let foodCategories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .foodMarket,
    ]

    private var query: String? {
        var parts: [String] = []
        if vegetarian { parts.append("vegetarian") }
        if let cuisine {
            parts.append(cuisine.query)
        } else if takeaway || vegetarian {
            parts.append("restaurant")
        }
        if takeaway { parts.append("takeaway") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func search(origin: CLLocationCoordinate2D?) async {
        guard let origin else {
            results = []
            return
        }
        isLoading = true
        failed = false
        defer { isLoading = false }

        do {
            let items = try await PlaceSearchService.nearby(query: query,
                                                            categories: Self.foodCategories,
                                                            center: origin,
                                                            radius: radius.rawValue)
            if Task.isCancelled { return }
            let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            results = items.map { item in
                let c = item.placemark.coordinate
                return HungryResult(item: item,
                                    distance: here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
            }
        } catch {
            if Task.isCancelled { return }
            results = []
            // "No results" comes back as an error; only real failures are shown as such.
            failed = (error as? MKError)?.code != .placemarkNotFound
        }
    }
}
