import Foundation
import CoreLocation

/// Public transport journey planning from Transitous (transitous.org): a free, community-run service
/// that combines the official timetables of many countries. Best effort, no live guarantees.
/// Its rules: send an identifying User-Agent, keep the volume low, open-source non-commercial use.
enum TransitousService {
    static let endpoint = "https://api.transitous.org/api/v6/plan"
    static let userAgent = "TripPlanner/1.0 (+https://github.com/skysurfer1508/trip-planner)"

    enum Timing {
        case departAt(Date)
        case arriveBy(Date)
    }

    static func plan(from: CLLocationCoordinate2D,
                     to: CLLocationCoordinate2D,
                     timing: Timing) async throws -> [TransitItinerary] {
        guard var components = URLComponents(string: endpoint) else { return [] }
        let instant: Date
        let arriveBy: Bool
        switch timing {
        case .departAt(let date): instant = date; arriveBy = false
        case .arriveBy(let date): instant = date; arriveBy = true
        }
        components.queryItems = [
            URLQueryItem(name: "fromPlace", value: "\(from.latitude),\(from.longitude)"),
            URLQueryItem(name: "toPlace", value: "\(to.latitude),\(to.longitude)"),
            URLQueryItem(name: "time", value: TransitTime.requestString(instant)),
            URLQueryItem(name: "arriveBy", value: arriveBy ? "true" : "false"),
            URLQueryItem(name: "numItineraries", value: "3"),
            URLQueryItem(name: "detailedLegs", value: "true"),
        ]
        guard let url = components.url else { return [] }
        let json = try await Net.json(url: url, headers: ["User-Agent": userAgent])
        return parse(json)
    }

    // MARK: Parsing

    static func parse(_ json: [String: Any]) -> [TransitItinerary] {
        let rows = json["itineraries"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let legs = (row["legs"] as? [[String: Any]] ?? []).compactMap(leg)
            guard !legs.isEmpty else { return nil }
            return TransitItinerary(duration: Net.int(row["duration"]) ?? legs.reduce(0) { $0 + $1.duration },
                                    transfers: Net.int(row["transfers"]) ?? 0,
                                    start: TransitTime.parse(row["startTime"] as? String),
                                    end: TransitTime.parse(row["endTime"] as? String),
                                    legs: legs)
        }
    }

    private static func leg(_ row: [String: Any]) -> TransitLeg? {
        guard let from = row["from"] as? [String: Any], let to = row["to"] as? [String: Any],
              let fromLat = Net.double(from["lat"]), let fromLon = Net.double(from["lon"]),
              let toLat = Net.double(to["lat"]), let toLon = Net.double(to["lon"]) else { return nil }

        var path: [TransitPoint] = []
        if let geometry = row["legGeometry"] as? [String: Any], let points = geometry["points"] as? String {
            let precision = Net.int(geometry["precision"]) ?? 6
            path = Polyline.decode(points, precision: precision).map { TransitPoint(lat: $0.latitude, lon: $0.longitude) }
        }

        func name(_ place: [String: Any], _ fallback: String) -> String {
            let raw = (place["name"] as? String) ?? fallback
            switch raw {
            case "START": return "Start"
            case "END": return "Destination"
            default: return raw
            }
        }

        let color = (row["routeColor"] as? String)?.replacingOccurrences(of: "#", with: "")
        return TransitLeg(mode: TransitMode(motis: (row["mode"] as? String) ?? "OTHER"),
                          fromName: name(from, "Start"),
                          toName: name(to, "Destination"),
                          from: TransitPoint(lat: fromLat, lon: fromLon),
                          to: TransitPoint(lat: toLat, lon: toLon),
                          departure: TransitTime.parse((from["departure"] as? String) ?? (from["scheduledDeparture"] as? String)),
                          arrival: TransitTime.parse((to["arrival"] as? String) ?? (to["scheduledArrival"] as? String)),
                          routeShortName: nonEmpty(row["routeShortName"]),
                          routeLongName: nonEmpty(row["routeLongName"]),
                          headsign: nonEmpty(row["headsign"]),
                          agencyName: nonEmpty(row["agencyName"]),
                          colorHex: (color?.count == 6) ? color : nil,
                          distance: Net.double(row["distance"]) ?? 0,
                          duration: Net.int(row["duration"]) ?? 0,
                          stopCount: (row["intermediateStops"] as? [Any])?.count ?? 0,
                          path: path)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}
