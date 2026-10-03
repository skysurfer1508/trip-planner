import Foundation
import CoreLocation

struct TAPlace: Sendable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String
    let rating: Double?
    let reviews: Int?
    let ranking: String?
    let url: URL?
    let cuisines: [String]
    let priceLevel: String?
}

/// Ratings, review counts and rankings from the Tripadvisor Content API.
///
/// Notes for Tripadvisor's terms: results must show Tripadvisor attribution and link back to
/// `url`, and are only cached in memory for the current session.
enum TripadvisorService {
    private static let base = "https://api.content.tripadvisor.com/api/v1/location"

    private actor Cache {
        var store: [String: (date: Date, place: TAPlace)] = [:]

        func get(_ id: String) -> TAPlace? {
            guard let entry = store[id], Date().timeIntervalSince(entry.date) < 3600 else { return nil }
            return entry.place
        }

        func set(_ place: TAPlace) {
            store[place.id] = (Date(), place)
        }
    }

    private static let cache = Cache()

    /// `category` is "attractions", "restaurants" or "hotels". Returns up to 10 places, best
    /// matches first, each with its details (one nearby search plus one details call each).
    static func nearby(category: String,
                       center: CLLocationCoordinate2D,
                       radiusKm: Double,
                       key: String) async throws -> [TAPlace] {
        guard var components = URLComponents(string: "\(base)/nearby_search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "latLong", value: "\(center.latitude),\(center.longitude)"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "radius", value: String(Int(min(50, max(1, radiusKm))))),
            URLQueryItem(name: "radiusUnit", value: "km"),
            URLQueryItem(name: "language", value: "en"),
        ]
        guard let url = components.url else { return [] }

        let json = try await Net.json(url: url, headers: ["accept": "application/json"])
        let rows = json["data"] as? [[String: Any]] ?? []
        let ids = rows.compactMap { $0["location_id"] as? String }.prefix(10)

        var places: [TAPlace] = []
        await withTaskGroup(of: TAPlace?.self) { group in
            for id in ids {
                group.addTask { await details(id: id, key: key) }
            }
            for await place in group {
                if let place { places.append(place) }
            }
        }
        return places
    }

    static func details(id: String, key: String) async -> TAPlace? {
        if let cached = await cache.get(id) { return cached }

        guard var components = URLComponents(string: "\(base)/\(id)/details") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "currency", value: "EUR"),
        ]
        guard let url = components.url,
              let json = try? await Net.json(url: url, headers: ["accept": "application/json"]),
              let name = json["name"] as? String,
              let lat = Net.double(json["latitude"]),
              let lon = Net.double(json["longitude"]) else { return nil }

        let cuisines = (json["cuisine"] as? [[String: Any]] ?? []).compactMap {
            ($0["localized_name"] as? String) ?? ($0["name"] as? String)
        }
        let ranking = (json["ranking_data"] as? [String: Any])?["ranking_string"] as? String
        let address = (json["address_obj"] as? [String: Any])?["address_string"] as? String

        let place = TAPlace(id: id,
                            name: name,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            address: address ?? "",
                            rating: Net.double(json["rating"]),
                            reviews: Net.int(json["num_reviews"]),
                            ranking: ranking,
                            url: (json["web_url"] as? String).flatMap { URL(string: $0) },
                            cuisines: cuisines,
                            priceLevel: json["price_level"] as? String)
        await cache.set(place)
        return place
    }

    /// Maps rating and review count to 0...1 (many reviews count as more trustworthy).
    static func score(rating: Double, reviews: Int?) -> Double {
        let quality = min(1, max(0, rating / 5))
        let volume = min(1, log10(Double(reviews ?? 0) + 1) / 4)
        return quality * 0.65 + volume * 0.35
    }
}
