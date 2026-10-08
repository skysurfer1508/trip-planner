import Foundation

/// Asks OpenStreetMap's Overpass API. The public servers are often busy or down, so several are tried
/// in turn; the first that answers with data wins.
enum OverpassClient {
    static let hosts = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    enum Failure: Error {
        case noServerAnswered
    }

    /// The decoded answer (`elements`), or an error when no server answered.
    static func query(_ ql: String, session: URLSession = Net.cached) async throws -> [String: Any] {
        guard let encoded = ql.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw Failure.noServerAnswered
        }
        for host in hosts {
            if Task.isCancelled { throw CancellationError() }
            guard let url = URL(string: "\(host)?data=\(encoded)") else { continue }
            if let json = try? await Net.json(url: url, session: session), json["elements"] is [Any] {
                return json
            }
        }
        throw Failure.noServerAnswered
    }
}
