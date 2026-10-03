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

    /// Text search used for Apple Maps.
    var query: String {
        switch self {
        case .cafe: "cafe"
        case .bakery: "bakery"
        default: "\(rawValue) restaurant"
        }
    }

    /// Words matched against Tripadvisor's cuisine tags.
    var keywords: [String] {
        switch self {
        case .asian: ["asian", "chinese", "japanese", "thai", "vietnamese", "korean", "sushi", "ramen"]
        case .italian: ["italian", "pizza", "pasta"]
        case .pizza: ["pizza"]
        case .burger: ["burger", "american", "fast food"]
        case .sushi: ["sushi", "japanese"]
        case .indian: ["indian"]
        case .mexican: ["mexican"]
        case .cafe: ["cafe", "café", "coffee"]
        case .bakery: ["bakery", "pastry"]
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

enum HungrySource: String, CaseIterable, Identifiable {
    case nearby = "Nearby"
    case topRated = "Top rated"

    var id: String { rawValue }
}

struct HungryResult: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String
    let distance: CLLocationDistance
    var category: StopCategory = .food
    var rating: Double?
    var reviews: Int?
    var ranking: String?
    var cuisines: [String] = []
    var url: URL?

    var walkMinutes: Int { max(1, Int((distance * 1.25 / TravelMode.walk.fallbackSpeed / 60).rounded())) }
}

@Observable
final class HungryViewModel {
    var cuisine: Cuisine?
    var takeaway = false
    var vegetarian = false
    var radius: SearchRadius = .medium
    var source: HungrySource = .nearby

    var results: [HungryResult] = []
    var isLoading = false
    var failed = false
    var errorMessage: String?

    /// Changes whenever a filter changes; the view re-runs the search on it.
    var searchKey: String {
        "\(source.rawValue)-\(cuisine?.rawValue ?? "all")-\(takeaway)-\(vegetarian)-\(radius.rawValue)"
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

    func search(origin: CLLocationCoordinate2D?, tripadvisorKey: String) async {
        guard let origin else {
            results = []
            return
        }
        isLoading = true
        failed = false
        errorMessage = nil
        defer { isLoading = false }

        if source == .topRated && !tripadvisorKey.isEmpty {
            await searchTripadvisor(origin: origin, key: tripadvisorKey)
        } else {
            await searchApple(origin: origin)
        }
    }

    private func searchApple(origin: CLLocationCoordinate2D) async {
        do {
            let items = try await PlaceSearchService.nearby(query: query,
                                                            categories: Self.foodCategories,
                                                            center: origin,
                                                            radius: radius.rawValue)
            if Task.isCancelled { return }
            let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            results = items.map { item in
                let c = item.placemark.coordinate
                return HungryResult(name: item.name ?? "Restaurant",
                                    coordinate: c,
                                    address: item.placemark.title ?? "",
                                    distance: here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                                    category: StopCategory(poi: item.pointOfInterestCategory) == .cafe ? .cafe : .food)
            }
        } catch {
            if Task.isCancelled { return }
            results = []
            // "No results" comes back as an error; only real failures are shown as such.
            failed = (error as? MKError)?.code != .placemarkNotFound
        }
    }

    private func searchTripadvisor(origin: CLLocationCoordinate2D, key: String) async {
        do {
            let places = try await TripadvisorService.nearby(category: "restaurants",
                                                             center: origin,
                                                             radiusKm: radius.rawValue / 1000,
                                                             key: key)
            if Task.isCancelled { return }
            let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            var mapped = places.map { place in
                HungryResult(name: place.name,
                             coordinate: place.coordinate,
                             address: place.address,
                             distance: here.distance(from: CLLocation(latitude: place.coordinate.latitude,
                                                                      longitude: place.coordinate.longitude)),
                             rating: place.rating,
                             reviews: place.reviews,
                             ranking: place.ranking,
                             cuisines: place.cuisines,
                             url: place.url)
            }
            if let cuisine {
                mapped = mapped.filter { result in
                    let haystack = (result.cuisines + [result.name]).joined(separator: " ").lowercased()
                    return cuisine.keywords.contains { haystack.contains($0) }
                }
            }
            results = mapped.sorted {
                TripadvisorService.score(rating: $0.rating ?? 0, reviews: $0.reviews)
                    > TripadvisorService.score(rating: $1.rating ?? 0, reviews: $1.reviews)
            }
        } catch {
            if Task.isCancelled { return }
            results = []
            failed = true
            errorMessage = "Tripadvisor: \(error.localizedDescription)"
        }
    }
}
