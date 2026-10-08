import Foundation
import CoreLocation
import MapKit

/// Where you actually go into a metro or train station. The timetable only knows one point per station
/// (often a platform or the middle of the station), so the walk to it can end at the wrong side of
/// the block. Apple Maps is searched for the station's entrances first; OpenStreetMap
/// (`railway=subway_entrance`) fills in where Apple Maps lists none.
struct StationEntrance: Hashable {
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
        func get(_ key: String) -> [StationEntrance]? { store[key] }
        func set(_ key: String, _ value: [StationEntrance]) { store[key] = value }
    }

    private static let cache = Cache()

    /// Entrances of the station near `station` (the timetable's point for it). Remembered while the app runs.
    static func find(stationName: String, near station: CLLocationCoordinate2D) async -> [StationEntrance] {
        let key = "\(PlaceFinder.fold(stationName))|" + String(format: "%.4f,%.4f", station.latitude, station.longitude)
        if let known = await cache.get(key) { return known }

        var found = await appleMaps(stationName: stationName, near: station)
        if !found.contains(where: \.isEntrance) {
            found += await openStreetMap(near: station)
        }
        await cache.set(key, found)
        return found
    }

    /// Apple Maps: searches for the station's entrances and for the station itself.
    static func appleMaps(stationName: String, near station: CLLocationCoordinate2D) async -> [StationEntrance] {
        let region = MKCoordinateRegion(center: station, latitudinalMeters: 500, longitudinalMeters: 500)
        var result: [StationEntrance] = []
        for query in ["\(stationName) entrance", "\(stationName) metro entrance", stationName] {
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
            try? await Task.sleep(for: .milliseconds(150))
        }
        return result
    }

    /// OpenStreetMap: every `railway=subway_entrance` within 250 m, with its name or exit number.
    static func openStreetMap(near station: CLLocationCoordinate2D) async -> [StationEntrance] {
        let query = "[out:json][timeout:10];node(around:250,\(station.latitude),\(station.longitude))[\"railway\"=\"subway_entrance\"];out tags;"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        for host in ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"] {
            guard let url = URL(string: "\(host)?data=\(encoded)"),
                  let json = try? await Net.json(url: url, session: Net.cached) else { continue }
            return parseOverpass(json)
        }
        return []
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

/// Real walking routes from Apple Maps, for walks the timetable answer has no line for.
enum WalkingPath {
    private actor Cache {
        private var store: [String: [CLLocationCoordinate2D]] = [:]
        func get(_ key: String) -> [CLLocationCoordinate2D]? { store[key] }
        func set(_ key: String, _ value: [CLLocationCoordinate2D]) { store[key] = value }
    }

    private static let cache = Cache()

    /// The path along real streets, or nil when Apple Maps has none.
    static func fetch(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let key = TransitRouter.pairKey(from, to)
        if let known = await cache.get(key) { return known }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        await cache.set(key, coordinates)
        return coordinates
    }
}
