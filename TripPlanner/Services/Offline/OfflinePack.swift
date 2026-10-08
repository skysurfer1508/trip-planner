import Foundation
import CoreLocation
import Observation

/// What has to be fetched so a trip works without internet. The list is worked out from the plan alone
/// (no network, no database), so it can be tested; `OfflinePackRunner` carries it out.
struct OfflineDay {
    var date: Date
    var hotel: CLLocationCoordinate2D?
    var stops: [OfflineStop]
}

struct OfflineStop {
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// Minutes after midnight, when the stop has a time.
    var plannedMinute: Int?
    var durationMinutes: Int
}

enum OfflineTask {
    case timeZone
    case holidays
    case practicalInfo
    case transitGuide
    case route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, date: Date, minute: Int, arriveBy: Bool, label: String)
    case stopInfo(day: Int, stop: Int, name: String)

    var label: String {
        switch self {
        case .timeZone: "Time zone"
        case .holidays: "Public holidays"
        case .practicalInfo: "Practical information"
        case .transitGuide: "How public transport works"
        case .route(_, _, _, _, _, let label): label
        case .stopInfo(_, _, let name): name
        }
    }

    var kind: String {
        switch self {
        case .timeZone: "timeZone"
        case .holidays: "holidays"
        case .practicalInfo: "practicalInfo"
        case .transitGuide: "transitGuide"
        case .route: "route"
        case .stopInfo: "stopInfo"
        }
    }
}

enum OfflinePlanner {
    /// The routes use the same times as the Plan screen (arrive on time from the hotel, leave when the
    /// last stop ends), so the saved answers are exactly the ones the screen asks for.
    static func tasks(days: [OfflineDay], transit: Bool) -> [OfflineTask] {
        var list: [OfflineTask] = [.timeZone, .holidays, .practicalInfo]
        if transit { list.append(.transitGuide) }

        var seen = Set<String>()
        for (dayIndex, day) in days.enumerated() {
            var previous: (coordinate: CLLocationCoordinate2D, minute: Int, fromHotel: Bool, name: String)?
            if transit, let hotel = day.hotel {
                previous = (hotel, 9 * 60, true, "Hotel")
            }
            for (stopIndex, stop) in day.stops.enumerated() {
                if transit, let origin = previous {
                    let arrive = origin.fromHotel && stop.plannedMinute != nil
                    let minute = arrive ? (stop.plannedMinute ?? origin.minute) : origin.minute
                    let key = "\(TransitRouter.pairKey(origin.coordinate, stop.coordinate))|\(Int(day.date.timeIntervalSince1970))|\(minute)|\(arrive)"
                    if seen.insert(key).inserted {
                        list.append(.route(from: origin.coordinate, to: stop.coordinate, date: day.date, minute: minute,
                                           arriveBy: arrive, label: "\(origin.name) → \(stop.name)"))
                    }
                }
                list.append(.stopInfo(day: dayIndex, stop: stopIndex, name: stop.name))
                let leaves = stop.plannedMinute.map { $0 + stop.durationMinutes } ?? 10 * 60
                previous = (stop.coordinate, leaves, false, stop.name)
            }
        }
        return list
    }
}

/// Carries out the list: one thing after another, slowly enough for the free services, and stoppable.
@MainActor
@Observable
final class OfflinePackRunner {
    private(set) var total = 0
    private(set) var done = 0
    private(set) var failed = 0
    private(set) var running = false
    private(set) var current = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    func start(trip: Trip, geminiKey: String) {
        guard !running else { return }
        task = Task { await run(trip: trip, geminiKey: geminiKey) }
    }

    func cancel() {
        task?.cancel()
    }

    static func input(for trip: Trip) -> [OfflineDay] {
        trip.sortedDays.map { day in
            let stops = day.sortedStops.filter { !ExistingStops.isLogistics($0) }.map { stop in
                OfflineStop(name: stop.name,
                            coordinate: stop.coordinate,
                            plannedMinute: stop.plannedTime.map { WallClock.minute(of: $0) },
                            durationMinutes: stop.durationMinutes)
            }
            return OfflineDay(date: day.date, hotel: trip.window(for: day.date).anchor, stops: stops)
        }
    }

    private func run(trip: Trip, geminiKey: String) async {
        running = true
        done = 0
        failed = 0
        defer {
            running = false
            current = ""
        }
        let tasks = OfflinePlanner.tasks(days: Self.input(for: trip),
                                         transit: trip.transport == .transit && TransitRouter.isEnabled)
        total = tasks.count
        let zone = await TripTimeZone.ensure(trip)

        for item in tasks {
            if Task.isCancelled { return }
            current = item.label
            let ok = await perform(item, trip: trip, zone: zone, geminiKey: geminiKey)
            done += 1
            if !ok { failed += 1 }
        }
        trip.offlinePreparedAt = Date()
        trip.offlineNote = failed == 0 ? "Everything is saved on this iPhone."
                                       : "\(done - failed) of \(done) items saved; \(failed) need a connection and can be tried again."
    }

    private func perform(_ item: OfflineTask, trip: Trip, zone: TimeZone, geminiKey: String) async -> Bool {
        switch item {
        case .timeZone:
            _ = await TripTimeZone.ensure(trip)
            return !trip.timeZoneID.isEmpty
        case .holidays:
            await TripHolidays.ensure(trip)
            return !trip.holidaysJSON.isEmpty
        case .practicalInfo:
            await PracticalInfoService.ensure(for: trip, geminiKey: geminiKey)
            return !trip.practicalInfo.isEmpty
        case .transitGuide:
            await TransitGuide.ensure(for: trip, geminiKey: geminiKey)
            return !trip.transitGuide.isEmpty
        case .route(let from, let to, let date, let minute, let arriveBy, _):
            guard let time = WallClock.date(on: date, minute: minute) else { return true }
            let outcome = await TransitRouter.lookup(from: from, to: to,
                                                     timing: arriveBy ? .arriveBy(time) : .departAt(time), timeZone: zone)
            guard case .routes(let result) = outcome else {
                if case .noCoverage = outcome { return true }     // nothing to save, and not a failure
                return false
            }
            // Where you walk into the stations on the way.
            for leg in (result.best?.legs ?? []) where leg.mode == .subway || leg.mode == .rail {
                if Task.isCancelled { return true }
                _ = await TransitEntrances.find(stationName: leg.fromName, near: leg.from.coordinate)
                _ = await TransitEntrances.find(stationName: leg.toName, near: leg.to.coordinate)
            }
            return true
        case .stopInfo(let dayIndex, let stopIndex, _):
            let days = trip.sortedDays
            guard days.indices.contains(dayIndex) else { return true }
            let stops = days[dayIndex].sortedStops.filter { !ExistingStops.isLogistics($0) }
            guard stops.indices.contains(stopIndex) else { return true }
            await PlaceInfoLoader.ensureInfo(for: stops[stopIndex])
            await OpeningHoursLoader.ensureHours(for: stops[stopIndex])
            return true
        }
    }
}
