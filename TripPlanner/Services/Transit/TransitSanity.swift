import Foundation
import CoreLocation

/// Timetable search sometimes answers with routes nobody would take: a tram for 300 metres, a
/// 25-minute walk to a stop, a loop through the whole city. This keeps the routes that make sense,
/// offers walking when walking is about as fast, and puts the best one first.
enum TransitSanity {
    /// Metres per second on foot, and how much longer the streets are than the straight line.
    static let walkingSpeed = 1.3
    static let streetFactor = 1.25

    static func walkingSeconds(straight: Double) -> Int {
        Int((straight * streetFactor / walkingSpeed).rounded())
    }

    /// A route that is only a walk.
    static func walking(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> TransitItinerary {
        let straight = RoutingService.straightLine(from: from, to: to)
        let seconds = walkingSeconds(straight: straight)
        let leg = TransitLeg(mode: .walk, fromName: "Start", toName: "Destination",
                             from: TransitPoint(lat: from.latitude, lon: from.longitude),
                             to: TransitPoint(lat: to.latitude, lon: to.longitude),
                             distance: straight * streetFactor, duration: seconds, stopCount: 0, path: [])
        return TransitItinerary(duration: seconds, transfers: 0, start: nil, end: nil, legs: [leg])
    }

    /// Lower is better: time, with a penalty for changes and for walking (walking to a stop is
    /// worse than riding the same minutes).
    static func score(_ itinerary: TransitItinerary) -> Double {
        if itinerary.transitLegs.isEmpty {
            return Double(itinerary.duration) * 1.15
        }
        return Double(itinerary.duration) + 300 * Double(itinerary.transfers) + 1.5 * Double(itinerary.walkingSeconds)
    }

    /// Why a route is dropped: nil when it is fine.
    static func problem(with itinerary: TransitItinerary, straight: Double) -> String? {
        let vehicles = itinerary.transitLegs
        guard !vehicles.isEmpty else { return nil }
        if itinerary.transfers > 3 { return "too many changes" }
        if itinerary.walkingSeconds > 1500 { return "too much walking" }
        if itinerary.legs.contains(where: { $0.isWalking && $0.duration > 1200 }) { return "a very long walk to or from a stop" }
        // Riding a single stop over a few hundred metres is a walk, not a journey.
        if vehicles.contains(where: { $0.stopCount == 0 && $0.distance < 450 && $0.duration <= 180 }) {
            return "a ride of a single short stop"
        }
        // A loop through the city: far more distance than the way between the two places.
        let travelled = itinerary.legs.reduce(0) { $0 + $1.distance }
        if straight > 1_000 && travelled > max(straight * 2.6, straight + 4_000) { return "a big detour" }
        return nil
    }

    /// The sensible routes, best first (at most three, one per set of lines). Walking is included when it
    /// takes under 25 minutes. Never returns fewer routes than it must: if everything looks odd, the
    /// original answer stays so that coverage isn't lost.
    static func refine(_ itineraries: [TransitItinerary],
                       from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D) -> [TransitItinerary] {
        let straight = RoutingService.straightLine(from: from, to: to)
        let walk = walking(from: from, to: to)
        let walkSeconds = walk.duration

        var kept = itineraries.filter { problem(with: $0, straight: straight) == nil }
        // Transit that is hardly faster than walking is not worth the wait.
        if walkSeconds <= 1_800 {
            kept = kept.filter { $0.transitLegs.isEmpty || Double($0.duration) < Double(walkSeconds) * 0.95 }
        }
        var pool = kept
        if walkSeconds <= 1_500 && !pool.contains(where: { $0.transitLegs.isEmpty }) {
            pool.append(walk)
        }
        if pool.isEmpty { return itineraries }

        var seen = Set<String>()
        var result: [TransitItinerary] = []
        for itinerary in pool.sorted(by: { score($0) < score($1) }) {
            let signature = itinerary.transitLegs.map { "\($0.mode.rawValue)-\($0.routeShortName ?? "")" }.joined(separator: ">")
            guard seen.insert(signature).inserted else { continue }
            result.append(itinerary)
            if result.count == 3 { break }
        }
        return result
    }
}
