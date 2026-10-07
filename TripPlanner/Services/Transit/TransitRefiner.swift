import Foundation
import CoreLocation

/// After Auto plan has chosen the stops, replaces the straight-line travel guesses with real public
/// transport durations and schedules each day again.
@MainActor
enum TransitRefiner {
    struct Result {
        var days: [PlannedDay]
        /// Minutes per pair of places (`TransitRouter.pairKey`), for later edits.
        var minutes: [String: Int]
    }

    /// Only the first `maxDays` days are checked, to keep the number of requests small.
    static func refine(_ days: [PlannedDay],
                       prefs: TripPreferences,
                       windows: [DayWindow],
                       dates: [Date],
                       zone: TimeZone,
                       maxDays: Int = 5) async -> Result {
        var table: [String: Int] = [:]

        for (index, day) in days.enumerated().prefix(maxDays) {
            let date = dates.indices.contains(index) ? dates[index] : Date()
            let window = windows.indices.contains(index) ? windows[index] : DayWindow()
            var previous: (coordinate: CLLocationCoordinate2D, endMinute: Int)? = window.anchor.map {
                ($0, max(day.startOverride ?? prefs.dayStart.minutes, window.startMinute ?? 0))
            }
            for stop in day.stops {
                if let previous {
                    let outcome = await TransitRouter.lookup(from: previous.coordinate,
                                                             to: stop.candidate.coordinate,
                                                             timing: .departAt(wallClock(date, minute: previous.endMinute)),
                                                             timeZone: zone)
                    if let seconds = outcome.bestDuration {
                        table[TransitRouter.pairKey(previous.coordinate, stop.candidate.coordinate)] = Int((seconds / 60).rounded(.up))
                    }
                }
                previous = (stop.candidate.coordinate, stop.startMinute + stop.durationMinutes)
            }
        }

        let known = table
        guard !known.isEmpty else { return Result(days: days, minutes: known) }
        let override: TravelOverride = { a, b in known[TransitRouter.pairKey(a, b)] }

        let refined = days.enumerated().map { index, day -> PlannedDay in
            guard index < maxDays else { return day }
            let window = windows.indices.contains(index) ? windows[index] : DayWindow()
            let entries: [PlanEditor.Entry] = day.stops.map { ($0.candidate, $0.slot) }
            let stops = AutoPlanner.schedule(entries,
                                             prefs: prefs,
                                             from: window.anchor,
                                             startMinute: max(day.startOverride ?? prefs.dayStart.minutes, window.startMinute ?? 0),
                                             limit: min(prefs.endLimitMinutes, window.endMinute ?? Int.max),
                                             travelOverride: override)
            return PlannedDay(stops: stops, theme: day.theme, startOverride: day.startOverride)
        }
        return Result(days: refined, minutes: known)
    }

    private static func wallClock(_ date: Date, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: min(minute / 60, 23), minute: minute % 60, second: 0, of: date) ?? date
    }
}
