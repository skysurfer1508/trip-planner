import Foundation
import CoreLocation

struct OTMPlace {
    let xid: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let distance: Double
    let rate: Int
    let kinds: String
}

struct OTMDetail {
    let blurb: String?
    let imageURL: URL?
    let wikipediaURL: URL?
    let address: String?
}

/// Attractions with a popularity rating (0-3, 7 = heritage) from OpenTripMap. Free key.
enum OpenTripMapService {
    private static let base = "https://api.opentripmap.com/0.1/en/places"

    private struct FlexInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self) {
                value = Int(string.filter(\.isNumber)) ?? 0
            } else {
                value = 0
            }
        }
    }

    private struct RadiusItem: Decodable {
        struct Point: Decodable {
            let lon: Double
            let lat: Double
        }
        let xid: String?
        let name: String?
        let dist: Double?
        let rate: FlexInt?
        let kinds: String?
        let point: Point?
    }

    private struct DetailResponse: Decodable {
        struct Extracts: Decodable { let text: String? }
        struct Preview: Decodable { let source: String? }
        struct Address: Decodable {
            let road: String?
            let house_number: String?
            let city: String?
        }
        let wikipedia_extracts: Extracts?
        let preview: Preview?
        let wikipedia: String?
        let address: Address?
    }

    static func places(center: CLLocationCoordinate2D,
                       radius: Double,
                       kinds: String,
                       key: String) async throws -> [OTMPlace] {
        var places = try await fetch(center: center, radius: radius, kinds: kinds, minRate: "2", key: key)
        if places.count < 5 {
            places = try await fetch(center: center, radius: radius, kinds: kinds, minRate: nil, key: key)
        }
        return places
    }

    private static func fetch(center: CLLocationCoordinate2D,
                              radius: Double,
                              kinds: String,
                              minRate: String?,
                              key: String) async throws -> [OTMPlace] {
        guard var components = URLComponents(string: "\(base)/radius") else { return [] }
        var items = [
            URLQueryItem(name: "radius", value: String(Int(radius))),
            URLQueryItem(name: "lon", value: String(center.longitude)),
            URLQueryItem(name: "lat", value: String(center.latitude)),
            URLQueryItem(name: "kinds", value: kinds),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "60"),
            URLQueryItem(name: "apikey", value: key),
        ]
        if let minRate {
            items.append(URLQueryItem(name: "rate", value: minRate))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        let response = try await Net.get([RadiusItem].self, url: url, session: Net.cached)
        return response.compactMap { item in
            guard let xid = item.xid,
                  let name = item.name, !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  let point = item.point else { return nil }
            return OTMPlace(xid: xid,
                            name: name,
                            coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                            distance: item.dist ?? 0,
                            rate: item.rate?.value ?? 0,
                            kinds: item.kinds ?? "")
        }
    }

    static func detail(xid: String, key: String) async -> OTMDetail? {
        guard var components = URLComponents(string: "\(base)/xid/\(xid)") else { return nil }
        components.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components.url,
              let response = try? await Net.get(DetailResponse.self, url: url, session: Net.cached) else { return nil }

        let address = [response.address?.road, response.address?.house_number, response.address?.city]
            .compactMap { $0 }
            .joined(separator: " ")
        return OTMDetail(blurb: response.wikipedia_extracts?.text,
                         imageURL: response.preview?.source.flatMap { URL(string: $0) },
                         wikipediaURL: response.wikipedia.flatMap { URL(string: $0) },
                         address: address.isEmpty ? nil : address)
    }

    /// Maps OpenTripMap's rating to 0...1.
    static func score(rate: Int) -> Double {
        switch rate {
        case 7: 1.0
        case 3: 0.8
        case 2: 0.55
        case 1: 0.3
        default: 0.1
        }
    }
}
