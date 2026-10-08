import Foundation
import CoreLocation
import SwiftData

/// Opening hours from OpenStreetMap through the Overpass API (free, no key). OSM has good
/// coverage for museums, sights, shops and restaurants in most of Europe and in many big cities.
enum OpeningHoursService {
    /// Hours found for a place, and which OpenStreetMap object they came from.
    struct HoursMatch: Equatable {
        var hours: String
        /// The name of that object ("" when it has none).
        var source: String
        /// True when its name matches the place; false when it was only the nearest object.
        var byName: Bool
    }

    static func fetch(name: String, coordinate: CLLocationCoordinate2D, category: StopCategory = .other) async throws -> HoursMatch? {
        let query = "[out:json][timeout:12];nwr(around:70,\(coordinate.latitude),\(coordinate.longitude))[\"opening_hours\"];out tags center 15;"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encoded)") else { return nil }
        let json = try await Net.json(url: url, session: Net.cached)
        return pickMatch(from: json["elements"] as? [[String: Any]] ?? [], name: name, coordinate: coordinate, category: category)
    }

    /// Names an object can be known by: the local name and the translations and alternatives people add.
    private static func names(in tags: [String: Any]) -> [String] {
        ["name", "name:en", "alt_name", "official_name", "int_name", "old_name", "short_name", "brand"]
            .compactMap { tags[$0] as? String }
            .flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    private static func namesMatch(_ candidate: String, _ name: String) -> Bool {
        NameMatch.similar(candidate, name) || PlaceFinder.similarity(name, candidate) >= 0.75
    }

    /// The hours of the object that is this place. Only an object with a matching name counts, or, for
    /// shops, restaurants and the like, one right next to the point. A sight or museum never borrows the
    /// hours of a souvenir shop or bureau de change next door.
    static func pickMatch(from elements: [[String: Any]],
                          name: String,
                          coordinate: CLLocationCoordinate2D,
                          category: StopCategory = .food) -> HoursMatch? {
        struct Candidate {
            var hours: String
            var names: [String]
            var distance: Double
        }
        let candidates: [Candidate] = elements.compactMap { element in
            guard let tags = element["tags"] as? [String: Any],
                  let hours = tags["opening_hours"] as? String else { return nil }
            let center = element["center"] as? [String: Any]
            guard let lat = Net.double(element["lat"] ?? center?["lat"]),
                  let lon = Net.double(element["lon"] ?? center?["lon"]) else { return nil }
            let distance = RoutingService.straightLine(from: coordinate, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            return Candidate(hours: hours, names: names(in: tags), distance: distance)
        }
        if let named = candidates.filter({ candidate in candidate.names.contains { namesMatch($0, name) } })
            .min(by: { $0.distance < $1.distance }) {
            let source = named.names.first { namesMatch($0, name) } ?? named.names.first ?? ""
            return HoursMatch(hours: named.hours, source: source, byName: true)
        }
        guard category != .sight else { return nil }
        if let nearest = candidates.filter({ $0.distance <= 15 }).min(by: { $0.distance < $1.distance }) {
            return HoursMatch(hours: nearest.hours, source: nearest.names.first ?? "an unnamed place next to it", byName: false)
        }
        return nil
    }

    static func pick(from elements: [[String: Any]],
                     name: String,
                     coordinate: CLLocationCoordinate2D,
                     category: StopCategory = .food) -> String? {
        pickMatch(from: elements, name: name, coordinate: coordinate, category: category)?.hours
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
        // Hours saved before the source was kept may belong to a neighbouring shop: look again once.
        let unverified = !stop.openingHours.isEmpty && stop.hoursSource.isEmpty
        if !force && !unverified && stop.hoursCheckedAt != nil { return }
        let id = stop.persistentModelID
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let name = stop.name
        let coordinate = stop.coordinate
        let category = stop.category

        await gate.enter()
        let result: Result<OpeningHoursService.HoursMatch?, Error>
        do {
            result = .success(try await OpeningHoursService.fetch(name: name, coordinate: coordinate, category: category))
        } catch {
            result = .failure(error)
        }
        await gate.leave()

        guard stop.modelContext != nil else { return }
        if case .success(let match) = result {
            stop.openingHours = match?.hours ?? ""
            stop.hoursSource = match?.source ?? ""
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
