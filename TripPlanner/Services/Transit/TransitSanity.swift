import Foundation
import CoreLocation

/// Timetable search sometimes answers with routes nobody would take: a tram for 300 metres, a
/// 25-minute walk to a stop, a loop through the whole city. This keeps the routes that make sense,
/// offers walking when walking is about as fast, and puts the best one first.
enum TransitSanity {
    /// Every tuning value in one place.
    struct Limits {
        var walkingSpeed = 1.3                 // metres per second on foot
        var streetFactor = 1.25                // streets are this much longer than the straight line
        var maxTransfers = 3
        var maxWalkingSeconds = 1_500          // all walking to, between and from stops
        var maxSingleWalkSeconds = 1_200
        var hopMaxMeters = 450.0               // a ride of a single stop over less than this is a walk
        var hopMaxSeconds = 180
        var detourFactor = 2.6                 // distance travelled against the straight line...
        var detourExtraMeters = 4_000.0        // ...or this much more, whichever is larger
        var detourMinStraight = 1_000.0
        var offerWalkUpToSeconds = 1_800       // walking is offered, and transit must beat it, up to this
        var transitMustBeat = 0.95
        var fallbackWalkSeconds = 2_700        // if nothing else is sensible, walk up to this
        var transferPenaltySeconds = 300.0
        var walkingPenalty = 1.5               // walking to a stop counts this much more than riding
        var walkOnlyBias = 1.15                // slight preference for a ride when times are close
        var waitWeight = 0.5                   // waiting for the first departure
        var maxResults = 3
    }

    static let limits = Limits()

    /// Metres per second on foot, and how much longer the streets are than the straight line.
    static var walkingSpeed: Double { limits.walkingSpeed }
    static var streetFactor: Double { limits.streetFactor }

    static func walkingSeconds(straight: Double) -> Int {
        Int((straight * limits.streetFactor / limits.walkingSpeed).rounded())
    }

    /// A route that is only a walk.
    static func walking(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> TransitItinerary {
        let straight = RoutingService.straightLine(from: from, to: to)
        let seconds = walkingSeconds(straight: straight)
        let leg = TransitLeg(mode: .walk, fromName: "Start", toName: "Destination",
                             from: TransitPoint(lat: from.latitude, lon: from.longitude),
                             to: TransitPoint(lat: to.latitude, lon: to.longitude),
                             distance: straight * limits.streetFactor, duration: seconds, stopCount: 0, path: [])
        return TransitItinerary(duration: seconds, transfers: 0, start: nil, end: nil, legs: [leg])
    }

    /// Lower is better: time, with a penalty for changes, for walking (walking to a stop is worse than
    /// riding the same minutes) and for waiting until the first departure.
    static func score(_ itinerary: TransitItinerary, requestedAt: Date? = nil) -> Double {
        if itinerary.transitLegs.isEmpty {
            return Double(itinerary.duration) * limits.walkOnlyBias
        }
        var value = Double(itinerary.duration)
            + limits.transferPenaltySeconds * Double(itinerary.transfers)
            + limits.walkingPenalty * Double(itinerary.walkingSeconds)
        if let requestedAt, let start = itinerary.start {
            value += limits.waitWeight * max(0, start.timeIntervalSince(requestedAt))
        }
        return value
    }

    /// Why a route is dropped: nil when it is fine.
    static func problem(with itinerary: TransitItinerary, straight: Double) -> String? {
        let vehicles = itinerary.transitLegs
        guard !vehicles.isEmpty else { return nil }
        if itinerary.transfers > limits.maxTransfers { return "too many changes" }
        if itinerary.walkingSeconds > limits.maxWalkingSeconds { return "too much walking" }
        if itinerary.legs.contains(where: { $0.isWalking && $0.duration > limits.maxSingleWalkSeconds }) {
            return "a very long walk to or from a stop"
        }
        // Riding a single stop over a few hundred metres is a walk, not a journey.
        if vehicles.contains(where: { $0.stopCount == 0 && $0.distance < limits.hopMaxMeters && $0.duration <= limits.hopMaxSeconds }) {
            return "a ride of a single short stop"
        }
        // A loop through the city: far more distance than the way between the two places.
        let travelled = itinerary.legs.reduce(0) { $0 + $1.distance }
        if straight > limits.detourMinStraight,
           travelled > max(straight * limits.detourFactor, straight + limits.detourExtraMeters) {
            return "a big detour"
        }
        return nil
    }

    /// What tells two routes apart: the lines, or for unnamed ones the trip itself.
    static func signature(_ itinerary: TransitItinerary) -> String {
        itinerary.transitLegs.map { leg in
            let line = leg.routeShortName ?? leg.routeLongName ?? leg.tripId ?? ""
            return "\(leg.mode.rawValue)-\(line)"
        }
        .joined(separator: ">")
    }

    /// The sensible routes, best first (at most three, one per set of lines). Walking is included when it
    /// takes under 30 minutes and public transport doesn't clearly beat it. Never leaves nothing: if every
    /// route looks odd, a walk (when it isn't too far) or the best of the original answers is used.
    static func refine(_ itineraries: [TransitItinerary],
                       from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D,
                       requestedAt: Date? = nil) -> [TransitItinerary] {
        let straight = RoutingService.straightLine(from: from, to: to)
        let walk = walking(from: from, to: to)
        let walkSeconds = walk.duration

        var pool = itineraries.filter { problem(with: $0, straight: straight) == nil }
        if walkSeconds <= limits.offerWalkUpToSeconds {
            // Transit that is hardly faster than walking is not worth the wait.
            pool = pool.filter { $0.transitLegs.isEmpty || Double($0.duration) < Double(walkSeconds) * limits.transitMustBeat }
            if !pool.contains(where: { $0.transitLegs.isEmpty }) { pool.append(walk) }
        }
        if pool.isEmpty {
            if walkSeconds <= limits.fallbackWalkSeconds { return [walk] }
            return itineraries.sorted { score($0, requestedAt: requestedAt) < score($1, requestedAt: requestedAt) }
        }

        var seen = Set<String>()
        var result: [TransitItinerary] = []
        for itinerary in pool.sorted(by: { score($0, requestedAt: requestedAt) < score($1, requestedAt: requestedAt) }) {
            guard seen.insert(signature(itinerary)).inserted else { continue }
            result.append(itinerary)
            if result.count == limits.maxResults { break }
        }
        return result
    }
}
