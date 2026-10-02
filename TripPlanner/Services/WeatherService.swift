import Foundation
import CoreLocation

struct DayWeather: Equatable {
    let code: Int
    let high: Double
    let low: Double
    let rainChance: Int

    var isWet: Bool {
        rainChance >= 50 || (51...99).contains(code)
    }

    var symbol: String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: "cloud.heavyrain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    var summary: String {
        "\(Int(high.rounded()))° / \(Int(low.rounded()))°"
    }
}

/// Daily forecast from Open-Meteo: free, no API key, no account. Covers about 16 days ahead,
/// so trips further away simply show no weather.
enum WeatherService {
    private struct Response: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let weathercode: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]
        }
        let daily: Daily
    }

    static func forecast(for date: Date, at coordinate: CLLocationCoordinate2D) async -> DayWeather? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "daily", value: "weathercode,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let daily = decoded.daily
            guard !daily.time.isEmpty,
                  let code = daily.weathercode.first ?? nil,
                  let high = daily.temperature_2m_max.first ?? nil,
                  let low = daily.temperature_2m_min.first ?? nil else { return nil }
            let rain = (daily.precipitation_probability_max.first ?? nil) ?? 0
            return DayWeather(code: code, high: high, low: low, rainChance: rain)
        } catch {
            return nil
        }
    }
}
