import Foundation
import CoreLocation

enum TransitMode: String, Codable {
    case walk, bus, tram, subway, rail, ferry, cableCar, other

    /// Maps the mode names of the MOTIS API (BUS, TRAM, SUBWAY, REGIONAL_RAIL, ...).
    init(motis raw: String) {
        let value = raw.uppercased()
        if value == "WALK" { self = .walk }
        else if value.contains("SUBWAY") { self = .subway }
        else if value.contains("TRAM") { self = .tram }
        else if value.contains("BUS") || value.contains("COACH") { self = .bus }
        else if value.contains("FERRY") { self = .ferry }
        else if value.contains("CABLE") || value.contains("FUNICULAR") || value.contains("AERIAL") { self = .cableCar }
        else if value.contains("RAIL") || value.contains("SUBURBAN") || value.contains("LONG_DISTANCE") { self = .rail }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .walk: "Walk"
        case .bus: "Bus"
        case .tram: "Tram"
        case .subway: "Metro"
        case .rail: "Train"
        case .ferry: "Ferry"
        case .cableCar: "Cable car"
        case .other: "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .bus: "bus.fill"
        case .tram: "tram.fill"
        case .subway: "tram.fill.tunnel"
        case .rail: "train.side.front.car"
        case .ferry: "ferry.fill"
        case .cableCar: "cablecar.fill"
        case .other: "arrow.triangle.branch"
        }
    }
}

struct TransitPoint: Codable {
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct TransitLeg: Codable {
    var mode: TransitMode
    var fromName: String
    var toName: String
    var from: TransitPoint
    var to: TransitPoint
    var departure: Date?
    var arrival: Date?
    var routeShortName: String?
    var routeLongName: String?
    var headsign: String?
    var agencyName: String?
    /// Line colour as 6 hex digits without "#", when the agency publishes one.
    var colorHex: String?
    var distance: Double
    /// Seconds.
    var duration: Int
    var stopCount: Int
    var path: [TransitPoint]

    var isWalking: Bool { mode == .walk }

    var coordinates: [CLLocationCoordinate2D] {
        path.isEmpty ? [from.coordinate, to.coordinate] : path.map(\.coordinate)
    }

    /// "Tram 28", "Bus 728", "Walk 4 min".
    var label: String {
        if isWalking { return "Walk \(Format.duration(TimeInterval(duration)))" }
        let line = routeShortName ?? routeLongName ?? ""
        return line.isEmpty ? mode.title : "\(mode.title) \(line)"
    }
}

struct TransitItinerary: Codable {
    /// Seconds door to door.
    var duration: Int
    var transfers: Int
    var start: Date?
    var end: Date?
    var legs: [TransitLeg]

    var transitLegs: [TransitLeg] { legs.filter { !$0.isWalking } }

    var walkingSeconds: Int { legs.filter(\.isWalking).reduce(0) { $0 + $1.duration } }

    /// The mode shown next to the summary: the first vehicle, or walking.
    var headlineMode: TransitMode { transitLegs.first?.mode ?? .walk }

    /// "Tram 28 → Bus 728 · 55 min · 1 change"
    var summary: String {
        let total = Format.duration(TimeInterval(duration))
        guard !transitLegs.isEmpty else { return "Walk \(total)" }
        let lines = transitLegs.map(\.label).joined(separator: " → ")
        let changes = transfers == 0 ? "direct" : "\(transfers) \(transfers == 1 ? "change" : "changes")"
        return "\(lines) · \(total) · \(changes)"
    }
}
