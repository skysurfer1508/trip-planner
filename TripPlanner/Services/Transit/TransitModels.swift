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
    /// Live data. All optional, so routes saved before they existed still open.
    var realTime: Bool?
    var cancelled: Bool?
    /// What the timetable says, when the live time differs.
    var scheduledDeparture: Date?
    var scheduledArrival: Date?
    var fromStopId: String?
    var tripId: String?

    var isWalking: Bool { mode == .walk }

    /// True when the agency sends live positions for this trip.
    var isLive: Bool { realTime ?? false }
    var isCancelled: Bool { cancelled ?? false }

    /// Minutes later (+) or earlier (-) than the timetable; nil without live data.
    var departureDelayMinutes: Int? {
        guard isLive, let departure, let scheduledDeparture else { return nil }
        return Int((departure.timeIntervalSince(scheduledDeparture) / 60).rounded())
    }

    var arrivalDelayMinutes: Int? {
        guard isLive, let arrival, let scheduledArrival else { return nil }
        return Int((arrival.timeIntervalSince(scheduledArrival) / 60).rounded())
    }

    enum Status: Equatable {
        case scheduled
        case onTime
        case late(Int)
        case early(Int)
        case cancelled
    }

    var status: Status {
        if isCancelled { return .cancelled }
        guard isLive else { return .scheduled }
        let delay = departureDelayMinutes ?? 0
        if delay >= 1 { return .late(delay) }
        if delay <= -1 { return .early(-delay) }
        return .onTime
    }

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
    /// The service's id for this journey, used to ask for fresh live data.
    var id: String?

    var hasLiveData: Bool { legs.contains { $0.isLive } }
    var hasCancelledLeg: Bool { legs.contains { $0.isCancelled } }

    /// When the first vehicle leaves (live if known).
    var firstDeparture: Date? { transitLegs.first?.departure }

    /// Minutes between getting off one vehicle and the next one leaving, walking included, per change.
    /// A small number with a delay in it means the connection may be missed.
    var changeSlackMinutes: [Int] {
        var result: [Int] = []
        var arrival: Date?
        var walking: TimeInterval = 0
        for leg in legs {
            if leg.isWalking {
                if arrival != nil { walking += TimeInterval(leg.duration) }
                continue
            }
            if let previous = arrival, let departure = leg.departure {
                result.append(Int(((departure.timeIntervalSince(previous) - walking) / 60).rounded(.down)))
            }
            arrival = leg.arrival
            walking = 0
        }
        return result
    }

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
