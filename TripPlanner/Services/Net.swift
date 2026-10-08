import Foundation

enum NetError: LocalizedError {
    case badStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            switch code {
            case 401, 403: "The API key was rejected (\(code)). Check it in Settings."
            case 429: "Too many requests. Try again in a minute."
            default: "The server answered with status \(code)."
            }
        case .badResponse: "Unexpected response from the server."
        }
    }
}

enum Net {
    /// For data that rarely changes (places, Wikipedia). Responses are kept on disk and reused when
    /// offline.
    static let cached: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 150_000_000)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static let live: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func data(url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("TripPlanner/1.0 (personal iOS app)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw NetError.badStatus(http.statusCode) }
            return data
        } catch {
            // Cancelled lookups (a list scrolled away) are not failures.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                Diagnostics.shared.record(service: Diagnostics.service(for: url), message: error.localizedDescription)
            }
            throw error
        }
    }

    static func get<T: Decodable>(_ type: T.Type,
                                  url: URL,
                                  headers: [String: String] = [:],
                                  session: URLSession = Net.live) async throws -> T {
        let payload = try await data(url: url, headers: headers, session: session)
        return try JSONDecoder().decode(T.self, from: payload)
    }

    /// Raw bytes of a URL, e.g. an image.
    static func bytes(url: URL, session: URLSession = Net.live) async throws -> Data {
        try await data(url: url, headers: [:], session: session)
    }

    /// Like `json`, for endpoints that answer with a list. An empty answer (204) is an empty list.
    static func jsonArray(url: URL,
                          headers: [String: String] = [:],
                          session: URLSession = Net.live) async throws -> [[String: Any]] {
        let payload = try await data(url: url, headers: headers, session: session)
        if payload.isEmpty { return [] }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
            throw NetError.badResponse
        }
        return object
    }

    /// For APIs whose field types vary (numbers sent as strings and so on).
    static func json(url: URL,
                     headers: [String: String] = [:],
                     session: URLSession = Net.live) async throws -> [String: Any] {
        let payload = try await data(url: url, headers: headers, session: session)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw NetError.badResponse
        }
        return object
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.replacingOccurrences(of: ",", with: "")) }
        return nil
    }
}
