import Foundation

struct WikiSummary {
    let title: String
    let extract: String
    let thumbnail: URL?
    let pageURL: URL?
}

/// Short descriptions and photos from Wikipedia. Free, no key.
enum WikipediaService {
    private struct Response: Decodable {
        struct Thumbnail: Decodable { let source: String }
        struct Urls: Decodable {
            struct Page: Decodable { let page: String }
            let mobile: Page?
            let desktop: Page?
        }
        let title: String
        let extract: String?
        let thumbnail: Thumbnail?
        let content_urls: Urls?
    }

    static func summary(title: String) async -> WikiSummary? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
              let response = try? await Net.get(Response.self, url: url, session: Net.cached) else { return nil }
        let page = response.content_urls?.mobile?.page ?? response.content_urls?.desktop?.page
        return WikiSummary(title: response.title,
                           extract: response.extract ?? "",
                           thumbnail: response.thumbnail.flatMap { URL(string: $0.source) },
                           pageURL: page.flatMap { URL(string: $0) })
    }
}
