import Foundation
import CoreLocation
import CryptoKit
import SwiftData

struct TransitResult {
    var itineraries: [TransitItinerary]
    /// The date was too far ahead for timetables, so the next same weekday and time was used.
    var isTypical: Bool
    var fromCache: Bool
    var timeZone: TimeZone
    /// When the answer was obtained from the service (not when it was read from the cache).
    var fetchedAt = Date()

    var best: TransitItinerary? { itineraries.first }

    /// The same answer with one journey replaced by a fresher one.
    func replacing(_ itinerary: TransitItinerary, at index: Int) -> TransitResult {
        guard itineraries.indices.contains(index) else { return self }
        var copy = self
        copy.itineraries[index] = itinerary
        copy.fromCache = false
        copy.fetchedAt = Date()
        return copy
    }

    var hasLiveData: Bool { itineraries.contains { $0.hasLiveData } }
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

    static func read(_ key: String, maxAge: TimeInterval) -> (itineraries: [TransitItinerary], isTypical: Bool, savedAt: Date)? {
        guard let url = file(for: key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(entry.savedAt) < maxAge else { return nil }
        return (entry.itineraries, entry.isTypical, entry.savedAt)
    }

    static func write(_ key: String, itineraries: [TransitItinerary], isTypical: Bool) {
        guard let url = file(for: key),
              let data = try? JSONEncoder().encode(Entry(itineraries: itineraries, isTypical: isTypical, savedAt: Date())) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// How long an answer stays fresh. Live data goes stale in a minute or two; a timetable for next week
/// stays right for weeks.
enum LivePolicy {
    /// A departure from 10 minutes ago to 3 hours ahead is covered by live data.
    static let pastWindow: TimeInterval = 10 * 60
    static let futureWindow: TimeInterval = 3 * 3_600
    static let refreshInterval: TimeInterval = 60

    static func isLive(departure: Date, now: Date = Date()) -> Bool {
        let offset = departure.timeIntervalSince(now)
        return offset >= -pastWindow && offset <= futureWindow
    }

    /// Seconds an answer for `instant` may be reused.
    static func cacheAge(for instant: Date, isNow: Bool, now: Date = Date()) -> TimeInterval {
        if isNow { return 60 }
        return isLive(departure: instant, now: now) ? 90 : 30 * 86_400
    }

    /// Answers for departures inside the live window are grouped by 5 minutes, the others by 15.
    static func bucketSeconds(for instant: Date, isNow: Bool, now: Date = Date()) -> Int {
        isNow || isLive(departure: instant, now: now) ? 300 : 900
    }
}

/// One gate for every call to the timetable service: two at a time, a pause between them, and a cool-down
/// after the service answers with an error, so a busy server isn't asked again and again.
actor TransitNetwork {
    static let shared = TransitNetwork()

    enum Failure: LocalizedError {
        case busy
        var errorDescription: String? { "The timetable service is busy. Try again in a minute." }
    }

    private let gate = RequestGate(limit: 2, minGap: 0.25)
    private var cooldownUntil = Date.distantPast

    func enter() async throws {
        if Date() < cooldownUntil { throw Failure.busy }
        try await gate.enter()
    }

    func leave() async {
        await gate.leave()
    }

    /// Call with every error: a refusal or a server error starts a cool-down.
    func note(_ error: Error) {
        if case NetError.badStatus(let code) = error, code == 429 || code >= 500 {
            cooldownUntil = Date().addingTimeInterval(60)
        } else if let url = error as? URLError, url.code != .cancelled {
            cooldownUntil = Date().addingTimeInterval(15)
        }
    }
}

/// Finds the best public transport route between two points and remembers it.
@MainActor
enum TransitRouter {
    static let settingsKey = "transitRoutesEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Stable key for a pair of places (about 1 m precision).
    nonisolated static func pairKey(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f>%.5f,%.5f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// The prefix changes whenever what is saved changes shape, so old files are simply not found.
    nonisolated static func cacheKey(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, instant: Date,
                                     arriveBy: Bool, bucketSeconds: Int = 900) -> String {
        let bucket = Int(instant.timeIntervalSince1970 / Double(bucketSeconds))
        return "v2|\(pairKey(from, to))|\(bucket)|\(arriveBy ? "arrive" : "depart")"
    }

    private static var inFlight: [String: Task<TransitOutcome, Never>] = [:]
    /// Places the service has no timetable for: not asked again for ten minutes.
    private static var noCoverageUntil: [String: Date] = [:]

    /// `refresh` ignores what is saved (used when live data must be fetched again).
    static func lookup(from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D,
                       timing: TransitTiming,
                       timeZone: TimeZone,
                       refresh: Bool = false) async -> TransitOutcome {
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

        let key = cacheKey(from: from, to: to, instant: query.instant, arriveBy: arriveBy,
                           bucketSeconds: LivePolicy.bucketSeconds(for: query.instant, isNow: isNow))
        if !refresh, let cached = TransitDiskCache.read(key, maxAge: LivePolicy.cacheAge(for: query.instant, isNow: isNow)) {
            // What is saved is the service's own answer; the sanity check is applied each time it is read.
            let sensible = TransitSanity.refine(cached.itineraries, from: from, to: to, requestedAt: arriveBy ? nil : query.instant)
            return .routes(TransitResult(itineraries: sensible, isTypical: cached.isTypical,
                                         fromCache: true, timeZone: timeZone, fetchedAt: cached.savedAt))
        }
        if !refresh, let until = noCoverageUntil[key], until > Date() {
            return .noCoverage(estimate: nil)
        }
        if let running = inFlight[key], !refresh {
            return await running.value
        }

        let task = Task { await fetch(key: key, from: from, to: to, query: query, arriveBy: arriveBy, timeZone: timeZone) }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    private static func fetch(key: String,
                              from: CLLocationCoordinate2D,
                              to: CLLocationCoordinate2D,
                              query: (instant: Date, isTypical: Bool),
                              arriveBy: Bool,
                              timeZone: TimeZone) async -> TransitOutcome {
        do {
            try await TransitNetwork.shared.enter()
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            let itineraries = try await TransitousService.plan(from: from, to: to,
                                                               timing: arriveBy ? .arriveBy(query.instant) : .departAt(query.instant))
            await TransitNetwork.shared.leave()
            let sensible = TransitSanity.refine(itineraries, from: from, to: to, requestedAt: arriveBy ? nil : query.instant)
            if hasUsefulRoute(sensible) {
                TransitDiskCache.write(key, itineraries: itineraries, isTypical: query.isTypical)
                return .routes(TransitResult(itineraries: sensible, isTypical: query.isTypical,
                                             fromCache: false, timeZone: timeZone))
            }
            noCoverageUntil[key] = Date().addingTimeInterval(600)
            return .noCoverage(estimate: await RoutingService.eta(from: from, to: to, mode: .transit))
        } catch {
            await TransitNetwork.shared.leave()
            await TransitNetwork.shared.note(error)
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
    /// One lookup at a time per trip: a plan with many connectors asks at once, and a failed lookup
    /// is not repeated for each of them.
    private static var running: [PersistentIdentifier: Task<TimeZone, Never>] = [:]
    private static var failedAt: [PersistentIdentifier: Date] = [:]

    static func ensure(_ trip: Trip) async -> TimeZone {
        if let zone = TimeZone(identifier: trip.timeZoneID), !trip.timeZoneID.isEmpty, !trip.countryCode.isEmpty {
            return zone
        }
        let id = trip.persistentModelID
        if let running = running[id] { return await running.value }
        if let failed = failedAt[id], Date().timeIntervalSince(failed) < 120 { return trip.timeZone }
        guard let coordinate = trip.destinationCoordinate ?? trip.anyCoordinate else { return trip.timeZone }

        let task = Task { () -> TimeZone in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let placemark = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first {
                if let zone = placemark.timeZone { trip.timeZoneID = zone.identifier }
                if let code = placemark.isoCountryCode { trip.countryCode = code }
                if let country = placemark.country { trip.countryName = country }
            } else {
                failedAt[id] = Date()
            }
            return trip.timeZone
        }
        running[id] = task
        let zone = await task.value
        running[id] = nil
        return zone
    }
}
