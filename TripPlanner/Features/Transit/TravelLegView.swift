import SwiftUI
import CoreLocation

/// Travel time between two places in the way of getting around the traveller chose.
struct TravelLeg: Equatable {
    var mode: TravelMode
    var seconds: TimeInterval
    /// Street distance (the straight line plus a quarter).
    var meters: CLLocationDistance

    static func mode(for transport: TripPreferences.Transport) -> TravelMode {
        switch transport {
        case .walking: .walk
        case .transit: .transit
        case .car: .drive
        }
    }

    static func estimate(from: CLLocationCoordinate2D,
                         to: CLLocationCoordinate2D,
                         transport: TripPreferences.Transport) -> TravelLeg {
        let mode = mode(for: transport)
        let line = RoutingService.straightLine(from: from, to: to)
        return TravelLeg(mode: mode,
                         seconds: RoutingService.estimate(from: from, to: to, mode: mode),
                         meters: line * 1.25)
    }

    /// Walking more than this is tiring enough to be worth a note.
    static let longWalk: CLLocationDistance = 3_000

    var isLongWalk: Bool { mode == .walk && meters > Self.longWalk }

    var text: String {
        "\(Format.duration(seconds)) · \(Format.distance(meters))"
    }
}

/// Apple Maps travel times for walking and driving, asked for gently and remembered, so the
/// estimate shown first can be replaced by the real figure.
actor TravelTimeCache {
    static let shared = TravelTimeCache()

    private var known: [String: TimeInterval] = [:]
    private var failed = Set<String>()
    private let gate = RequestGate(limit: 2, minGap: 0.1)

    func seconds(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: TravelMode) async -> TimeInterval? {
        let key = "\(mode.rawValue)|" + TransitRouter.pairKey(from, to)
        if let value = known[key] { return value }
        if failed.contains(key) { return nil }
        do { try await gate.enter() } catch { return nil }
        let value = await RoutingService.eta(from: from, to: to, mode: mode)
        await gate.leave()
        if let value {
            known[key] = value
        } else if !Task.isCancelled {
            failed.insert(key)
        }
        return value
    }
}

/// One line between two places: how long it takes and how far it is, in the preferred way of
/// getting around. With public transport it is the real route (tap for the details).
struct TravelLegView: View {
    let trip: Trip?
    let fromName: String
    let toName: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    /// Wall-clock time of leaving, or of having to arrive, for timetable lookups.
    var departAt: Date?
    var arriveBy: Date?
    /// "to the first stop"
    var suffix: String?
    var inset: CGFloat = 36

    @State private var refined: TimeInterval?

    private var transport: TripPreferences.Transport { trip?.transport ?? .walking }

    private var currentLeg: TravelLeg {
        var value = TravelLeg.estimate(from: from, to: to, transport: transport)
        if let refined { value.seconds = refined }
        return value
    }

    var body: some View {
        let leg = currentLeg
        let text = leg.text + (suffix.map { " \($0)" } ?? "")

        if transport == .transit, TransitRouter.isEnabled, let trip {
            TransitConnector(trip: trip, fromName: fromName, toName: toName, from: from, to: to,
                             timing: timing, fallback: text, inset: inset)
        } else {
            HStack(spacing: Spacing.s) {
                Image(systemName: leg.mode.symbol)
                Text(text)
                if leg.isLongWalk {
                    Text("· long walk")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .task(id: TransitRouter.pairKey(from, to) + transport.rawValue) {
                refined = await TravelTimeCache.shared.seconds(from: from, to: to, mode: leg.mode)
            }
        }
    }

    private var timing: TransitTiming {
        if let arriveBy { return .arriveBy(arriveBy) }
        if let departAt { return .departAt(departAt) }
        return .now
    }
}
