import Foundation
import CoreLocation
import CryptoKit

struct TransitResult {
    var itineraries: [TransitItinerary]
    /// The date was too far ahead for timetables, so the next same weekday and time was used.
    var isTypical: Bool
    var fromCache: Bool
    var timeZone: TimeZone

    var best: TransitItinerary? { itineraries.first }
}

enum TransitOutcome {
    case routes(TransitResult)
    /// No timetable data for this area. `estimate` is Apple Maps' travel time, if it has one.
    case noCoverage(estimate: TimeInterval?)
    case failed(String)

    /// The best door-to-door time known, in seconds.
    var bestDuration: TimeInterval? {
        switch self {
        case .routes(let result): result.best.map { TimeInterval($0.duration) }
        case .noCoverage(let estimate): estimate
        case .failed: nil
        }
    }
}

enum TransitTiming {
    /// `wallClock` is a stop time as shown on the clock at the destination.
    case departAt(Date)
    case arriveBy(Date)
    /// Right now (Trip Mode).
    case now
}

/// Saves finished lookups on the device so a route is only asked for once and still opens offline.
enum TransitDiskCache {
    private struct Entry: Codable {
        var itineraries: [TransitItinerary]
        var isTypical: Bool
        var savedAt: Date
    }

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let url = base.appendingPathComponent("TransitRoutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest).appendingPathExtension("json")
    }

    static func read(_ key: String, maxAge: TimeInterval) -> (itineraries: [TransitItinerary], isTypical: Bool)? {
        guard let url = file(for: key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(entry.savedAt) < maxAge else { return nil }
        return (entry.itineraries, entry.isTypical)
    }

    static func write(_ key: String, itineraries: [TransitItinerary], isTypical: Bool) {
        guard let url = file(for: key),
              let data = try? JSONEncoder().encode(Entry(itineraries: itineraries, isTypical: isTypical, savedAt: Date())) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Keeps the number of requests to the free service small: two at a time, a short pause between.
private actor TransitGate {
    private var active = 0
    private var lastStart = Date.distantPast

    func enter() async {
        while active >= 2 {
            try? await Task.sleep(for: .milliseconds(150))
        }
        active += 1
        let wait = 0.25 - Date().timeIntervalSince(lastStart)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        lastStart = Date()
    }

    func leave() {
        active -= 1
    }
}

/// Finds the best public transport route between two points and remembers it.
@MainActor
enum TransitRouter {
    static let settingsKey = "transitRoutesEnabled"
    private static let gate = TransitGate()

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Stable key for a pair of places (about 1 m precision).
    nonisolated static func pairKey(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f>%.5f,%.5f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    nonisolated static func cacheKey(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, instant: Date, arriveBy: Bool) -> String {
        let bucket = Int(instant.timeIntervalSince1970 / 900)
        return "\(pairKey(from, to))|\(bucket)|\(arriveBy ? "arrive" : "depart")"
    }

    static func lookup(from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D,
                       timing: TransitTiming,
                       timeZone: TimeZone) async -> TransitOutcome {
        guard isEnabled else { return .failed("Public transport routes are turned off in Settings.") }

        var instant = Date()
        var arriveBy = false
        var isNow = false
        switch timing {
        case .now: isNow = true
        case .departAt(let wallClock): instant = TransitTime.instant(wallClock: wallClock, in: timeZone)
        case .arriveBy(let wallClock):
            instant = TransitTime.instant(wallClock: wallClock, in: timeZone)
            arriveBy = true
        }
        let query = isNow ? (instant: instant, isTypical: false) : TransitTime.queryInstant(for: instant, in: timeZone)

        let key = cacheKey(from: from, to: to, instant: query.instant, arriveBy: arriveBy)
        if let cached = TransitDiskCache.read(key, maxAge: isNow ? 20 * 60 : 30 * 86_400) {
            // Routes saved before the sanity check are checked now.
            let sensible = TransitSanity.refine(cached.itineraries, from: from, to: to)
            return .routes(TransitResult(itineraries: sensible, isTypical: cached.isTypical,
                                         fromCache: true, timeZone: timeZone))
        }

        await gate.enter()
        do {
            let itineraries = try await TransitousService.plan(from: from, to: to,
                                                               timing: arriveBy ? .arriveBy(query.instant) : .departAt(query.instant))
            await gate.leave()
            let sensible = TransitSanity.refine(itineraries, from: from, to: to)
            if hasUsefulRoute(sensible) {
                TransitDiskCache.write(key, itineraries: sensible, isTypical: query.isTypical)
                return .routes(TransitResult(itineraries: sensible, isTypical: query.isTypical,
                                             fromCache: false, timeZone: timeZone))
            }
            return .noCoverage(estimate: await RoutingService.eta(from: from, to: to, mode: .transit))
        } catch {
            await gate.leave()
            return .failed(error.localizedDescription)
        }
    }

    /// A route with a vehicle in it, or a short walk. A long walk-only answer means "no timetable here".
    nonisolated static func hasUsefulRoute(_ itineraries: [TransitItinerary]) -> Bool {
        if itineraries.contains(where: { !$0.transitLegs.isEmpty }) { return true }
        return (itineraries.first?.duration ?? .max) <= 25 * 60
    }
}

/// The time zone of the trip's destination, found once and kept on the trip.
@MainActor
enum TripTimeZone {
    static func ensure(_ trip: Trip) async -> TimeZone {
        if let zone = TimeZone(identifier: trip.timeZoneID), !trip.timeZoneID.isEmpty, !trip.countryCode.isEmpty {
            return zone
        }
        guard let coordinate = trip.destinationCoordinate ?? trip.anyCoordinate else { return trip.timeZone }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemark = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first {
            if let zone = placemark.timeZone { trip.timeZoneID = zone.identifier }
            if let code = placemark.isoCountryCode { trip.countryCode = code }
            if let country = placemark.country { trip.countryName = country }
        }
        return trip.timeZone
    }
}
