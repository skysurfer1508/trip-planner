import Foundation
import MapKit

enum DiscoverKind: String, CaseIterable, Identifiable {
    case sights, culture, nature, food, fun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sights: "Top sights"
        case .culture: "Culture"
        case .nature: "Nature"
        case .food: "Food"
        case .fun: "Fun"
        }
    }

    var symbol: String {
        switch self {
        case .sights: "star.fill"
        case .culture: "building.columns.fill"
        case .nature: "leaf.fill"
        case .food: "fork.knife"
        case .fun: "figure.run"
        }
    }

    /// OpenTripMap "kinds" filter.
    var otmKinds: String {
        switch self {
        case .sights: "interesting_places"
        case .culture: "museums,historic,architecture,cultural"
        case .nature: "natural"
        case .food: "foods"
        case .fun: "amusements,sport"
        }
    }

    var tripadvisorCategory: String {
        self == .food ? "restaurants" : "attractions"
    }

    var stopCategory: StopCategory {
        switch self {
        case .food: .food
        default: .sight
        }
    }

    /// Used when no API keys are set.
    var appleCategories: [MKPointOfInterestCategory] {
        switch self {
        case .sights: [.museum, .park, .nationalPark, .beach, .zoo, .aquarium, .amusementPark, .theater]
        case .culture: [.museum, .theater, .library, .university]
        case .nature: [.park, .nationalPark, .beach]
        case .food: [.restaurant, .cafe, .bakery, .foodMarket]
        case .fun: [.amusementPark, .zoo, .aquarium, .stadium, .theater, .nightlife]
        }
    }
}

struct SuggestedPlace: Identifiable {
    let id: String
    var name: String
    var coordinate: CLLocationCoordinate2D
    var kind: DiscoverKind
    var distance: CLLocationDistance
    var otmXid: String?
    var otmRate: Int?
    var rating: Double?
    var reviews: Int?
    var ranking: String?
    var tripadvisorURL: URL?
    var cuisines: [String] = []
    var address: String?
    var isApple = false
    var score: Double = 0
}

struct SuggestionResult {
    var places: [SuggestedPlace]
    var notices: [String]
}

/// Combines OpenTripMap, Tripadvisor and (as a fallback) Apple Maps into one ranked list.
enum SuggestionService {
    static func load(kind: DiscoverKind,
                     center: CLLocationCoordinate2D,
                     radiusMeters: Double,
                     keys: APIKeys) async -> SuggestionResult {
        async let otm = fetchOpenTripMap(kind: kind, center: center, radius: radiusMeters, key: keys.openTripMap)
        async let ta = fetchTripadvisor(kind: kind, center: center, radius: radiusMeters, key: keys.tripadvisor)
        let (otmResult, taResult) = await (otm, ta)

        let notices = [otmResult.notice, taResult.notice].compactMap { $0 }
        var places = merge([otmResult.places, taResult.places])

        if places.isEmpty && notices.isEmpty {
            places = await fetchApple(kind: kind, center: center, radius: radiusMeters)
        }
        for index in places.indices {
            places[index].score = score(places[index])
        }
        return SuggestionResult(places: places, notices: notices)
    }

    // MARK: Sources

    private static func fetchOpenTripMap(kind: DiscoverKind,
                                         center: CLLocationCoordinate2D,
                                         radius: Double,
                                         key: String) async -> (places: [SuggestedPlace], notice: String?) {
        guard !key.isEmpty else { return ([], nil) }
        do {
            let found = try await OpenTripMapService.places(center: center, radius: radius, kinds: kind.otmKinds, key: key)
            let places = found.map { place in
                SuggestedPlace(id: "otm-\(place.xid)",
                               name: place.name,
                               coordinate: place.coordinate,
                               kind: kind,
                               distance: place.distance,
                               otmXid: place.xid,
                               otmRate: place.rate)
            }
            return (places, nil)
        } catch {
            return ([], "OpenTripMap: \(error.localizedDescription)")
        }
    }

    private static func fetchTripadvisor(kind: DiscoverKind,
                                         center: CLLocationCoordinate2D,
                                         radius: Double,
                                         key: String) async -> (places: [SuggestedPlace], notice: String?) {
        guard !key.isEmpty else { return ([], nil) }
        do {
            let found = try await TripadvisorService.nearby(category: kind.tripadvisorCategory,
                                                            center: center,
                                                            radiusKm: radius / 1000,
                                                            key: key)
            let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let places = found.map { place in
                SuggestedPlace(id: "ta-\(place.id)",
                               name: place.name,
                               coordinate: place.coordinate,
                               kind: kind,
                               distance: origin.distance(from: CLLocation(latitude: place.coordinate.latitude,
                                                                          longitude: place.coordinate.longitude)),
                               rating: place.rating,
                               reviews: place.reviews,
                               ranking: place.ranking,
                               tripadvisorURL: place.url,
                               cuisines: place.cuisines,
                               address: place.address.isEmpty ? nil : place.address)
            }
            return (places, nil)
        } catch {
            return ([], "Tripadvisor: \(error.localizedDescription)")
        }
    }

    private static func fetchApple(kind: DiscoverKind,
                                   center: CLLocationCoordinate2D,
                                   radius: Double) async -> [SuggestedPlace] {
        guard let items = try? await PlaceSearchService.nearby(query: nil,
                                                               categories: kind.appleCategories,
                                                               center: center,
                                                               radius: radius) else { return [] }
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.map { item in
            let c = item.placemark.coordinate
            return SuggestedPlace(id: "apple-\(item.name ?? "")-\(c.latitude)-\(c.longitude)",
                                  name: item.name ?? "Place",
                                  coordinate: c,
                                  kind: kind,
                                  distance: origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                                  address: item.placemark.title,
                                  isApple: true)
        }
    }

    // MARK: Merging and scoring

    private static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.filter { $0.isLetter || $0.isNumber }
    }

    private static func isSame(_ a: SuggestedPlace, _ b: SuggestedPlace) -> Bool {
        let close = RoutingService.straightLine(from: a.coordinate, to: b.coordinate) < 150
        guard close else { return false }
        let na = normalized(a.name)
        let nb = normalized(b.name)
        return !na.isEmpty && !nb.isEmpty && (na == nb || na.contains(nb) || nb.contains(na))
    }

    private static func merge(_ lists: [[SuggestedPlace]]) -> [SuggestedPlace] {
        var result: [SuggestedPlace] = []
        for place in lists.flatMap({ $0 }) {
            if let index = result.firstIndex(where: { isSame($0, place) }) {
                var merged = result[index]
                merged.otmXid = merged.otmXid ?? place.otmXid
                merged.otmRate = merged.otmRate ?? place.otmRate
                merged.rating = merged.rating ?? place.rating
                merged.reviews = merged.reviews ?? place.reviews
                merged.ranking = merged.ranking ?? place.ranking
                merged.tripadvisorURL = merged.tripadvisorURL ?? place.tripadvisorURL
                merged.address = merged.address ?? place.address
                if merged.cuisines.isEmpty { merged.cuisines = place.cuisines }
                result[index] = merged
            } else {
                result.append(place)
            }
        }
        return result
    }

    static func score(_ place: SuggestedPlace) -> Double {
        var parts: [(value: Double, weight: Double)] = []
        if let rating = place.rating {
            parts.append((TripadvisorService.score(rating: rating, reviews: place.reviews), 0.7))
        }
        if let rate = place.otmRate {
            parts.append((OpenTripMapService.score(rate: rate), 0.3))
        }
        guard !parts.isEmpty else { return place.isApple ? 0.15 : 0.1 }
        let weight = parts.reduce(0) { $0 + $1.weight }
        return parts.reduce(0) { $0 + $1.value * $1.weight } / weight
    }
}
