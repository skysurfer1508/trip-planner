import Foundation
import CoreLocation

struct WikiSummary {
    let title: String
    let extract: String
    let thumbnail: URL?
    let pageURL: URL?
    let coordinate: CLLocationCoordinate2D?
    /// "standard", "disambiguation", ...
    let type: String?

    /// Wikipedia thumbnails are 320px wide; the same URL with a bigger size works for banners.
    var hero: URL? { thumbnailURL(width: 960) }

    func thumbnailURL(width: Int) -> URL? {
        guard let thumbnail else { return nil }
        let resized = thumbnail.absoluteString.replacingOccurrences(of: "/320px-", with: "/\(width)px-")
        return URL(string: resized) ?? thumbnail
    }
}

struct WikiHit {
    let title: String
    let distance: Double
}

/// Short descriptions and photos from Wikipedia. Free, no key. Text and images are CC BY-SA, so
/// the app shows where they come from.
enum WikipediaService {
    private struct Response: Decodable {
        struct Thumbnail: Decodable { let source: String }
        struct Urls: Decodable {
            struct Page: Decodable { let page: String }
            let mobile: Page?
            let desktop: Page?
        }
        struct Coordinates: Decodable {
            let lat: Double
            let lon: Double
        }
        let title: String
        let type: String?
        let extract: String?
        let thumbnail: Thumbnail?
        let content_urls: Urls?
        let coordinates: Coordinates?
    }

    /// Nil when there is no such article, throws when the request itself failed.
    static func fetchSummary(title: String, language: String = "en") async throws -> WikiSummary? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        do {
            let response = try await Net.get(Response.self, url: url, session: Net.cached)
            let page = response.content_urls?.mobile?.page ?? response.content_urls?.desktop?.page
            return WikiSummary(title: response.title,
                               extract: response.extract ?? "",
                               thumbnail: response.thumbnail.flatMap { URL(string: $0.source) },
                               pageURL: page.flatMap { URL(string: $0) },
                               coordinate: response.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                               type: response.type)
        } catch NetError.badStatus(404) {
            return nil
        }
    }

    static func summary(title: String) async -> WikiSummary? {
        try? await fetchSummary(title: title)
    }

    /// Geo-tagged articles around a point, nearest first.
    static func nearbyArticles(coordinate: CLLocationCoordinate2D,
                               radius: Int,
                               language: String = "en") async throws -> [WikiHit] {
        guard var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "geosearch"),
            URLQueryItem(name: "gscoord", value: "\(coordinate.latitude)|\(coordinate.longitude)"),
            URLQueryItem(name: "gsradius", value: String(min(max(radius, 10), 10_000))),
            URLQueryItem(name: "gslimit", value: "10"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        let json = try await Net.json(url: url, session: Net.cached)
        return parseGeosearch(json)
    }

    static func parseGeosearch(_ json: [String: Any]) -> [WikiHit] {
        let rows = (json["query"] as? [String: Any])?["geosearch"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            return WikiHit(title: title, distance: Net.double(row["dist"]) ?? .infinity)
        }
        .sorted { $0.distance < $1.distance }
    }
}
