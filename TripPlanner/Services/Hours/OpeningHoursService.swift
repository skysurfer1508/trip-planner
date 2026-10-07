import Foundation
import CoreLocation
import SwiftData

/// Opening hours from OpenStreetMap through the Overpass API (free, no key). OSM has good
/// coverage for museums, sights, shops and restaurants in most of Europe and in many big cities.
enum OpeningHoursService {
    static func fetch(name: String, coordinate: CLLocationCoordinate2D) async throws -> String? {
        let query = "[out:json][timeout:12];nwr(around:70,\(coordinate.latitude),\(coordinate.longitude))[\"opening_hours\"];out tags center 15;"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encoded)") else { return nil }
        let json = try await Net.json(url: url, session: Net.cached)
        return pick(from: json["elements"] as? [[String: Any]] ?? [], name: name, coordinate: coordinate)
    }

    /// The hours of the element that is this place: a matching name, else the very nearest one.
    static func pick(from elements: [[String: Any]], name: String, coordinate: CLLocationCoordinate2D) -> String? {
        struct Candidate {
            var hours: String
            var name: String?
            var distance: Double
        }
        let candidates: [Candidate] = elements.compactMap { element in
            guard let tags = element["tags"] as? [String: Any],
                  let hours = tags["opening_hours"] as? String else { return nil }
            let center = element["center"] as? [String: Any]
            guard let lat = Net.double(element["lat"] ?? center?["lat"]),
                  let lon = Net.double(element["lon"] ?? center?["lon"]) else { return nil }
            let distance = RoutingService.straightLine(from: coordinate, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            return Candidate(hours: hours, name: tags["name"] as? String, distance: distance)
        }
        if let named = candidates.filter({ $0.name.map { NameMatch.similar($0, name) } ?? false })
            .min(by: { $0.distance < $1.distance }) {
            return named.hours
        }
        return candidates.filter { $0.distance <= 25 }.min(by: { $0.distance < $1.distance })?.hours
    }
}

/// Keeps at most two lookups running and a small pause between them.
private actor HoursGate {
    private var active = 0
    private var lastStart = Date.distantPast

    func enter() async {
        while active >= 2 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        active += 1
        let wait = 0.4 - Date().timeIntervalSince(lastStart)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        lastStart = Date()
    }

    func leave() {
        active -= 1
    }
}

/// Fills in a stop's opening hours once and keeps them on the stop, so they work offline.
@MainActor
enum OpeningHoursLoader {
    private static var inFlight = Set<PersistentIdentifier>()
    private static let gate = HoursGate()

    static func shouldLookUp(_ stop: Stop) -> Bool {
        switch stop.category {
        case .hotel, .transport: return false
        default: return PlaceInfoService.shouldLookUp(name: stop.name, category: stop.category)
        }
    }

    static func ensureHours(for stop: Stop, force: Bool = false) async {
        guard shouldLookUp(stop) else { return }
        if !force && stop.hoursCheckedAt != nil { return }
        let id = stop.persistentModelID
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let name = stop.name
        let coordinate = stop.coordinate

        await gate.enter()
        let result: Result<String?, Error>
        do {
            result = .success(try await OpeningHoursService.fetch(name: name, coordinate: coordinate))
        } catch {
            result = .failure(error)
        }
        await gate.leave()

        guard stop.modelContext != nil else { return }
        if case .success(let hours) = result {
            stop.openingHours = hours ?? ""
            stop.hoursCheckedAt = Date()
        }
    }
}

/// Public holidays on the trip's dates, loaded once and kept on the trip.
@MainActor
enum TripHolidays {
    static func ensure(_ trip: Trip) async {
        _ = await TripTimeZone.ensure(trip)
        guard !trip.countryCode.isEmpty, trip.holidaysCountry != trip.countryCode || trip.holidaysJSON.isEmpty else { return }
        let calendar = Calendar.current
        let years = Set([calendar.component(.year, from: trip.startDate), calendar.component(.year, from: trip.endDate)])
        var all: [Holiday] = []
        for year in years.sorted() {
            guard let list = try? await PublicHolidays.fetch(year: year, country: trip.countryCode) else { return }
            all += list
        }
        if let data = try? JSONEncoder().encode(all) {
            trip.holidaysJSON = String(decoding: data, as: UTF8.self)
            trip.holidaysCountry = trip.countryCode
        }
    }
}
