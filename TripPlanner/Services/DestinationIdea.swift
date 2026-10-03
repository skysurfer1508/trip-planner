import Foundation
import CoreLocation

/// A curated "where to go" suggestion. Descriptions and photos are loaded from Wikipedia.
struct DestinationIdea: Identifiable, Hashable {
    let name: String
    let country: String
    let wikiTitle: String
    let latitude: Double
    let longitude: Double
    let tags: [String]

    var id: String { name + country }
    var displayName: String { "\(name), \(country)" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static let tags = ["City", "Beach", "Nature", "Culture", "Food", "Romantic"]

    static let all: [DestinationIdea] = [
        .init(name: "Lisbon", country: "Portugal", wikiTitle: "Lisbon", latitude: 38.7223, longitude: -9.1393, tags: ["City", "Culture", "Food"]),
        .init(name: "Porto", country: "Portugal", wikiTitle: "Porto", latitude: 41.1579, longitude: -8.6291, tags: ["City", "Food", "Romantic"]),
        .init(name: "Barcelona", country: "Spain", wikiTitle: "Barcelona", latitude: 41.3874, longitude: 2.1686, tags: ["City", "Beach", "Culture", "Food"]),
        .init(name: "Seville", country: "Spain", wikiTitle: "Seville", latitude: 37.3891, longitude: -5.9845, tags: ["City", "Culture", "Romantic"]),
        .init(name: "Palma de Mallorca", country: "Spain", wikiTitle: "Palma, Majorca", latitude: 39.5696, longitude: 2.6502, tags: ["Beach", "City"]),
        .init(name: "Rome", country: "Italy", wikiTitle: "Rome", latitude: 41.9028, longitude: 12.4964, tags: ["City", "Culture", "Food"]),
        .init(name: "Florence", country: "Italy", wikiTitle: "Florence", latitude: 43.7696, longitude: 11.2558, tags: ["City", "Culture", "Romantic"]),
        .init(name: "Amalfi Coast", country: "Italy", wikiTitle: "Amalfi Coast", latitude: 40.6340, longitude: 14.6027, tags: ["Beach", "Nature", "Romantic"]),
        .init(name: "Lake Como", country: "Italy", wikiTitle: "Lake Como", latitude: 45.9936, longitude: 9.2572, tags: ["Nature", "Romantic"]),
        .init(name: "Paris", country: "France", wikiTitle: "Paris", latitude: 48.8566, longitude: 2.3522, tags: ["City", "Culture", "Food", "Romantic"]),
        .init(name: "Nice", country: "France", wikiTitle: "Nice", latitude: 43.7102, longitude: 7.2620, tags: ["Beach", "City"]),
        .init(name: "Amsterdam", country: "Netherlands", wikiTitle: "Amsterdam", latitude: 52.3676, longitude: 4.9041, tags: ["City", "Culture"]),
        .init(name: "Berlin", country: "Germany", wikiTitle: "Berlin", latitude: 52.5200, longitude: 13.4050, tags: ["City", "Culture"]),
        .init(name: "Munich", country: "Germany", wikiTitle: "Munich", latitude: 48.1351, longitude: 11.5820, tags: ["City", "Food"]),
        .init(name: "Prague", country: "Czechia", wikiTitle: "Prague", latitude: 50.0755, longitude: 14.4378, tags: ["City", "Culture", "Romantic"]),
        .init(name: "Vienna", country: "Austria", wikiTitle: "Vienna", latitude: 48.2082, longitude: 16.3738, tags: ["City", "Culture", "Food"]),
        .init(name: "Budapest", country: "Hungary", wikiTitle: "Budapest", latitude: 47.4979, longitude: 19.0402, tags: ["City", "Culture"]),
        .init(name: "Interlaken", country: "Switzerland", wikiTitle: "Interlaken", latitude: 46.6863, longitude: 7.8632, tags: ["Nature"]),
        .init(name: "Copenhagen", country: "Denmark", wikiTitle: "Copenhagen", latitude: 55.6761, longitude: 12.5683, tags: ["City", "Food"]),
        .init(name: "Reykjavik", country: "Iceland", wikiTitle: "Reykjavík", latitude: 64.1466, longitude: -21.9426, tags: ["Nature", "City"]),
        .init(name: "Edinburgh", country: "United Kingdom", wikiTitle: "Edinburgh", latitude: 55.9533, longitude: -3.1883, tags: ["City", "Culture"]),
        .init(name: "London", country: "United Kingdom", wikiTitle: "London", latitude: 51.5072, longitude: -0.1276, tags: ["City", "Culture", "Food"]),
        .init(name: "Athens", country: "Greece", wikiTitle: "Athens", latitude: 37.9838, longitude: 23.7275, tags: ["City", "Culture", "Food"]),
        .init(name: "Santorini", country: "Greece", wikiTitle: "Santorini", latitude: 36.3932, longitude: 25.4615, tags: ["Beach", "Romantic"]),
        .init(name: "Dubrovnik", country: "Croatia", wikiTitle: "Dubrovnik", latitude: 42.6507, longitude: 18.0944, tags: ["City", "Beach", "Culture"]),
        .init(name: "Istanbul", country: "Türkiye", wikiTitle: "Istanbul", latitude: 41.0082, longitude: 28.9784, tags: ["City", "Culture", "Food"]),
        .init(name: "Marrakech", country: "Morocco", wikiTitle: "Marrakesh", latitude: 31.6295, longitude: -7.9811, tags: ["City", "Culture", "Food"]),
        .init(name: "Cape Town", country: "South Africa", wikiTitle: "Cape Town", latitude: -33.9249, longitude: 18.4241, tags: ["City", "Nature", "Beach"]),
        .init(name: "Dubai", country: "United Arab Emirates", wikiTitle: "Dubai", latitude: 25.2048, longitude: 55.2708, tags: ["City", "Beach"]),
        .init(name: "Tokyo", country: "Japan", wikiTitle: "Tokyo", latitude: 35.6762, longitude: 139.6503, tags: ["City", "Food", "Culture"]),
        .init(name: "Kyoto", country: "Japan", wikiTitle: "Kyoto", latitude: 35.0116, longitude: 135.7681, tags: ["Culture", "Nature", "Romantic"]),
        .init(name: "Seoul", country: "South Korea", wikiTitle: "Seoul", latitude: 37.5665, longitude: 126.9780, tags: ["City", "Food", "Culture"]),
        .init(name: "Bangkok", country: "Thailand", wikiTitle: "Bangkok", latitude: 13.7563, longitude: 100.5018, tags: ["City", "Food", "Culture"]),
        .init(name: "Ubud, Bali", country: "Indonesia", wikiTitle: "Ubud", latitude: -8.5069, longitude: 115.2625, tags: ["Nature", "Culture", "Romantic"]),
        .init(name: "Singapore", country: "Singapore", wikiTitle: "Singapore", latitude: 1.3521, longitude: 103.8198, tags: ["City", "Food"]),
        .init(name: "Hanoi", country: "Vietnam", wikiTitle: "Hanoi", latitude: 21.0278, longitude: 105.8342, tags: ["City", "Food", "Culture"]),
        .init(name: "Sydney", country: "Australia", wikiTitle: "Sydney", latitude: -33.8688, longitude: 151.2093, tags: ["City", "Beach"]),
        .init(name: "New York", country: "United States", wikiTitle: "New York City", latitude: 40.7128, longitude: -74.0060, tags: ["City", "Culture", "Food"]),
        .init(name: "San Francisco", country: "United States", wikiTitle: "San Francisco", latitude: 37.7749, longitude: -122.4194, tags: ["City", "Nature"]),
        .init(name: "Mexico City", country: "Mexico", wikiTitle: "Mexico City", latitude: 19.4326, longitude: -99.1332, tags: ["City", "Food", "Culture"]),
        .init(name: "Rio de Janeiro", country: "Brazil", wikiTitle: "Rio de Janeiro", latitude: -22.9068, longitude: -43.1729, tags: ["City", "Beach", "Nature"]),
    ]
}
