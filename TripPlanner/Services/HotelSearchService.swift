import Foundation
import MapKit

/// One place to stay found by search. The booking itself happens elsewhere; this only identifies
/// the place so the app knows where you sleep.
struct HotelResult: Identifiable {
    let id: String
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D?
    /// Straight-line distance from the destination's centre.
    var distanceFromCenter: CLLocationDistance?
    var phone: String?
    var website: String?
    /// A hotel, hostel or similar (as opposed to a plain address or other place).
    var isLodging: Bool
    var rating: Double?
    var reviews: Int?
    var ranking: String?
    var tripadvisorURL: URL?
    var priceLevel: String?

    var hasTripadvisorData: Bool { rating != nil }
}

enum HotelSort: String, CaseIterable, Identifiable {
    case bestMatch = "Best match"
    case closest = "Closest to centre"
    case topRated = "Top rated"

    var id: String { rawValue }
}

enum HotelSearchService {
    // MARK: Apple Maps

    /// Hotels, hostels, apartments and plain addresses matching a name or an address.
    static func search(query: String,
                       region: MKCoordinateRegion?,
                       center: CLLocationCoordinate2D?) async -> [HotelResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        async let lodging = run(query: text, region: region, onlyLodging: true)
        async let anything = run(query: text, region: region, onlyLodging: false)
        let (first, second) = await (lodging, anything)

        let primary = first.map { result(from: $0, center: center, forceLodging: true) }
        let extra = second.map { result(from: $0, center: center, forceLodging: false) }
        return merge(primary, with: extra)
    }

    /// Hotels around a point, nearest first.
    static func nearby(center: CLLocationCoordinate2D, radius: Double) async -> [HotelResult] {
        let items = (try? await PlaceSearchService.nearby(query: nil,
                                                          categories: [.hotel],
                                                          center: center,
                                                          radius: radius)) ?? []
        return items.prefix(30).map { result(from: $0, center: center, forceLodging: true) }
    }

    private static func run(query: String, region: MKCoordinateRegion?, onlyLodging: Bool) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        if onlyLodging {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.hotel])
            request.resultTypes = .pointOfInterest
        } else {
            request.resultTypes = [.pointOfInterest, .address]
        }
        return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    private static func result(from item: MKMapItem, center: CLLocationCoordinate2D?, forceLodging: Bool) -> HotelResult {
        let coordinate = item.placemark.coordinate
        let name = item.name ?? "Place"
        let lodging = forceLodging || item.pointOfInterestCategory == .hotel || looksLikeLodging(name)
        return HotelResult(id: "apple-\(name)-\(coordinate.latitude)-\(coordinate.longitude)",
                           name: name,
                           address: item.placemark.title ?? "",
                           coordinate: coordinate,
                           distanceFromCenter: center.map { RoutingService.straightLine(from: $0, to: coordinate) },
                           phone: item.phoneNumber,
                           website: item.url?.absoluteString,
                           isLodging: lodging)
    }

    // MARK: Tripadvisor (ratings only, optional)

    /// Hotels with ratings around the destination, to rate what Apple Maps found and to add
    /// well-reviewed places it missed.
    static func tripadvisorNearby(center: CLLocationCoordinate2D, key: String) async -> [HotelResult] {
        guard !key.isEmpty,
              let places = try? await TripadvisorService.nearby(category: "hotels", center: center, radiusKm: 10, key: key)
        else { return [] }
        return places.map { result(from: $0, center: center) }
    }

    /// Looks a hotel up by name on Tripadvisor (a few calls, so it runs when you press search).
    static func tripadvisorSearch(query: String, near center: CLLocationCoordinate2D?, key: String) async -> [HotelResult] {
        guard !key.isEmpty,
              let places = try? await TripadvisorService.search(query: query, category: "hotels", near: center, key: key)
        else { return [] }
        return places.map { result(from: $0, center: center) }
    }

    private static func result(from place: TAPlace, center: CLLocationCoordinate2D?) -> HotelResult {
        HotelResult(id: "ta-\(place.id)",
                    name: place.name,
                    address: place.address,
                    coordinate: place.coordinate,
                    distanceFromCenter: center.map { RoutingService.straightLine(from: $0, to: place.coordinate) },
                    phone: nil,
                    website: nil,
                    isLodging: true,
                    rating: place.rating,
                    reviews: place.reviews,
                    ranking: place.ranking,
                    tripadvisorURL: place.url,
                    priceLevel: place.priceLevel)
    }

    // MARK: Merging, matching and sorting (pure)

    static func normalized(_ name: String) -> String { NameMatch.normalized(name) }

    static func similar(_ a: String, _ b: String) -> Bool { NameMatch.similar(a, b) }

    static func isSame(_ a: HotelResult, _ b: HotelResult) -> Bool {
        guard let first = a.coordinate, let second = b.coordinate else { return similar(a.name, b.name) }
        return RoutingService.straightLine(from: first, to: second) < 150 && similar(a.name, b.name)
    }

    /// Adds `extra` to `base`. A place found twice keeps one row with the details of both.
    static func merge(_ base: [HotelResult], with extra: [HotelResult]) -> [HotelResult] {
        var result = base
        for item in extra {
            if let index = result.firstIndex(where: { isSame($0, item) }) {
                result[index].rating = result[index].rating ?? item.rating
                result[index].reviews = result[index].reviews ?? item.reviews
                result[index].ranking = result[index].ranking ?? item.ranking
                result[index].tripadvisorURL = result[index].tripadvisorURL ?? item.tripadvisorURL
                result[index].priceLevel = result[index].priceLevel ?? item.priceLevel
                result[index].phone = result[index].phone ?? item.phone
                result[index].website = result[index].website ?? item.website
                if result[index].address.isEmpty { result[index].address = item.address }
                result[index].isLodging = result[index].isLodging || item.isLodging
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Copies ratings (and missing contact details) onto matching results without adding new rows.
    static func enrich(_ results: [HotelResult], with extra: [HotelResult]) -> [HotelResult] {
        results.map { item in
            guard let match = extra.first(where: { isSame($0, item) }) else { return item }
            var copy = item
            copy.rating = copy.rating ?? match.rating
            copy.reviews = copy.reviews ?? match.reviews
            copy.ranking = copy.ranking ?? match.ranking
            copy.tripadvisorURL = copy.tripadvisorURL ?? match.tripadvisorURL
            copy.priceLevel = copy.priceLevel ?? match.priceLevel
            return copy
        }
    }

    /// 3 exact name, 2 name starts with the query, 1 name contains it, 0 otherwise.
    static func relevance(name: String, query: String) -> Int {
        let n = normalized(name)
        let q = normalized(query)
        guard !q.isEmpty else { return 0 }
        if n == q { return 3 }
        if n.hasPrefix(q) { return 2 }
        if n.contains(q) { return 1 }
        return 0
    }

    static func sorted(_ results: [HotelResult], by sort: HotelSort, query: String) -> [HotelResult] {
        func distance(_ r: HotelResult) -> Double { r.distanceFromCenter ?? .infinity }

        switch sort {
        case .bestMatch:
            return results.sorted { a, b in
                let ra = relevance(name: a.name, query: query)
                let rb = relevance(name: b.name, query: query)
                if ra != rb { return ra > rb }
                if a.isLodging != b.isLodging { return a.isLodging }
                return distance(a) < distance(b)
            }
        case .closest:
            return results.sorted { distance($0) < distance($1) }
        case .topRated:
            return results.sorted { a, b in
                switch (a.rating, b.rating) {
                case let (x?, y?):
                    if x != y { return x > y }
                    return (a.reviews ?? 0) > (b.reviews ?? 0)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return distance(a) < distance(b)
                }
            }
        }
    }

    static func looksLikeLodging(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["hotel", "hostel", "motel", "inn", "b&b", "guesthouse", "guest house", "pension", "apartment",
                "resort", "lodge", "residence", "villa", "suites", "albergue", "pousada", "gasthof"]
            .contains { lower.contains($0) }
    }
}
