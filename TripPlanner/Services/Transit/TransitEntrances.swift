import Foundation
import CoreLocation
import MapKit
import CryptoKit

/// Where you actually go into a metro or train station. The timetable only knows one point per station
/// (often a platform or the middle of the station), so the walk to it can end at the wrong side of
/// the block. Apple Maps is searched for the station's entrances first; OpenStreetMap
/// (`railway=subway_entrance`) fills in where Apple Maps lists none.
struct StationEntrance: Hashable, Codable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// "Apple Maps" or "OpenStreetMap".
    var source: String
    /// False when it is the station itself, as Apple Maps places it, not a named entrance.
    var isEntrance: Bool

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum TransitEntrances {
    private static let entranceWords = [
        "entrance", "exit", "entry", "wejście", "wejscie", "wyjście", "wyjscie", "eingang", "ausgang", "zugang",
        "entrée", "entree", "sortie", "ingresso", "uscita", "entrada", "salida", "ingang", "uitgang", "vchod",
        "výstup", "bejárat", "kijárat", "ingång", "utgång", "inngang", "indgang",
    ]

    /// "Centrum Metro Entrance", "Wejście do metra Ratusz" — not "Centrum Metro Station".
    static func looksLikeEntrance(_ name: String) -> Bool {
        let folded = PlaceFinder.fold(name)
        return entranceWords.contains { folded.contains(PlaceFinder.fold($0)) }
    }

    /// The entrance closest to `point`, preferring real entrances to the station marker.
    static func nearest(_ list: [StationEntrance], to point: CLLocationCoordinate2D) -> StationEntrance? {
        let real = list.filter(\.isEntrance)
        let pool = real.isEmpty ? list : real
        return pool.min {
            RoutingService.straightLine(from: $0.coordinate, to: point) < RoutingService.straightLine(from: $1.coordinate, to: point)
        }
    }

    // MARK: Lookup

    private actor Cache {
        private var store: [String: [StationEntrance]] = [:]
        private var running: [String: Task<[StationEntrance], Never>] = [:]

        func get(_ key: String) -> [StationEntrance]? { store[key] }
        func set(_ key: String, _ value: [StationEntrance]) { store[key] = value }

        /// One lookup per station at a time; callers asking meanwhile share its answer.
        func shared(_ key: String, _ work: @escaping @Sendable () async -> [StationEntrance]) async -> [StationEntrance] {
            if let task = running[key] { return await task.value }
            let task = Task { await work() }
            running[key] = task
            let value = await task.value
            running[key] = nil
            return value
        }
    }

    private static let cache = Cache()

    /// Entrances of the station near `station` (the timetable's point for it). OpenStreetMap first: it lists
    /// every entrance with its exit number. Apple Maps adds the station itself and any entrances it names.
    /// Answers are kept on the phone; a failed lookup is not kept, so it is tried again next time.
    static func find(stationName: String, near station: CLLocationCoordinate2D) async -> [StationEntrance] {
        let key = "\(PlaceFinder.fold(stationName))|" + String(format: "%.4f,%.4f", station.latitude, station.longitude)
        if let known = await cache.get(key) { return known }
        if let saved = EntranceDiskCache.read(key) {
            await cache.set(key, saved)
            return saved
        }
        return await cache.shared(key) {
            let osm = await openStreetMap(near: station)           // nil: no server answered
            var found = osm ?? []
            if !found.contains(where: \.isEntrance) {
                found += await appleMaps(stationName: stationName, near: station)
            }
            if osm != nil || !found.isEmpty {
                await cache.set(key, found)
                EntranceDiskCache.write(key, found)
            }
            return found
        }
    }

    /// Apple Maps: searches for the station's entrances and for the station itself.
    static func appleMaps(stationName: String, near station: CLLocationCoordinate2D) async -> [StationEntrance] {
        let region = MKCoordinateRegion(center: station, latitudinalMeters: 500, longitudinalMeters: 500)
        var result: [StationEntrance] = []
        for query in ["\(stationName) entrance", stationName] {
            guard await MapKitThrottle.shared.acquire() else { break }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = region
            request.resultTypes = .pointOfInterest
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            for item in items {
                let coordinate = item.placemark.coordinate
                guard RoutingService.straightLine(from: station, to: coordinate) <= 300 else { continue }
                let name = item.name ?? ""
                let entrance = looksLikeEntrance(name)
                let isStation = item.pointOfInterestCategory == .publicTransport
                    && PlaceFinder.similarity(stationName, name) >= 0.4
                guard entrance || isStation else { continue }
                // An entrance must belong to this station; "Exit" of another line two streets away doesn't.
                if entrance && PlaceFinder.similarity(stationName, name) < 0.2
                    && RoutingService.straightLine(from: station, to: coordinate) > 120 { continue }
                let candidate = StationEntrance(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                                source: "Apple Maps", isEntrance: entrance)
                if !result.contains(where: { RoutingService.straightLine(from: $0.coordinate, to: candidate.coordinate) < 15 && $0.isEntrance == candidate.isEntrance }) {
                    result.append(candidate)
                }
            }
            if result.contains(where: \.isEntrance) { break }
        }
        return result
    }

    /// OpenStreetMap: every `railway=subway_entrance` within 250 m, with its name or exit number.
    /// Nil when no server answered (an empty list means "none mapped here").
    static func openStreetMap(near station: CLLocationCoordinate2D) async -> [StationEntrance]? {
        let query = "[out:json][timeout:10];node(around:250,\(station.latitude),\(station.longitude))[\"railway\"=\"subway_entrance\"];out tags center;"
        guard let json = try? await OverpassClient.query(query) else { return nil }
        return parseOverpass(json)
    }

    static func parseOverpass(_ json: [String: Any]) -> [StationEntrance] {
        let elements = json["elements"] as? [[String: Any]] ?? []
        return elements.compactMap { element in
            guard let lat = Net.double(element["lat"]), let lon = Net.double(element["lon"]) else { return nil }
            let tags = element["tags"] as? [String: Any] ?? [:]
            var name = (tags["name"] as? String) ?? (tags["description"] as? String) ?? ""
            if name.isEmpty, let ref = tags["ref"] as? String { name = "Exit \(ref)" }
            if name.isEmpty { name = "Metro entrance" }
            return StationEntrance(name: name, latitude: lat, longitude: lon, source: "OpenStreetMap", isEntrance: true)
        }
    }
}

/// Entrances change rarely: kept on the phone for two months (a station with none mapped, for two days).
enum EntranceDiskCache {
    private struct Entry: Codable {
        var entrances: [StationEntrance]
        var savedAt: Date
    }

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let url = base.appendingPathComponent("StationEntrances", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest).appendingPathExtension("json")
    }

    static func maxAge(isEmpty: Bool) -> TimeInterval { isEmpty ? 2 * 86_400 : 60 * 86_400 }

    static func read(_ key: String, now: Date = Date()) -> [StationEntrance]? {
        guard let url = file(for: key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              now.timeIntervalSince(entry.savedAt) < maxAge(isEmpty: entry.entrances.isEmpty) else { return nil }
        return entry.entrances
    }

    static func write(_ key: String, _ entrances: [StationEntrance]) {
        guard let url = file(for: key),
              let data = try? JSONEncoder().encode(Entry(entrances: entrances, savedAt: Date())) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Real walking routes from Apple Maps, for walks the timetable answer has no line for.
enum WalkingPath {
    private actor Cache {
        private var store: [String: [CLLocationCoordinate2D]] = [:]
        private var failedAt: [String: Date] = [:]
        private var running: [String: Task<[CLLocationCoordinate2D]?, Never>] = [:]

        func get(_ key: String) -> [CLLocationCoordinate2D]? { store[key] }
        func recentlyFailed(_ key: String) -> Bool {
            guard let date = failedAt[key] else { return false }
            return Date().timeIntervalSince(date) < 300
        }

        func shared(_ key: String, _ work: @escaping @Sendable () async -> [CLLocationCoordinate2D]?) async -> [CLLocationCoordinate2D]? {
            if let task = running[key] { return await task.value }
            let task = Task { await work() }
            running[key] = task
            let value = await task.value
            running[key] = nil
            if let value { store[key] = value } else if !Task.isCancelled { failedAt[key] = Date() }
            return value
        }
    }

    private static let cache = Cache()

    /// The path along real streets, or nil when Apple Maps has none (not asked again for five minutes).
    static func fetch(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let key = TransitRouter.pairKey(from, to)
        if let known = await cache.get(key) { return known }
        if await cache.recentlyFailed(key) { return nil }
        return await cache.shared(key) {
            guard await MapKitThrottle.shared.acquire() else { return nil }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = .walking
            guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
            let polyline = route.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            return coordinates
        }
    }
}
