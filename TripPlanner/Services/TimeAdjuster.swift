import Foundation
import CoreLocation

/// Lays a day's stops out in time again after the order changed: each stop starts when the one before
/// ends, plus the way between them in the trip's way of getting around.
enum TimeAdjuster {
    /// Minutes of the way between two places, in the preferred way of getting around.
    static func travelMinutes(from: CLLocationCoordinate2D,
                              to: CLLocationCoordinate2D,
                              transport: TripPreferences.Transport,
                              transitMinutes: [String: Int] = [:]) -> Int {
        if let real = transitMinutes[TransitRouter.pairKey(from, to)] { return real }
        return Int((TravelLeg.estimate(from: from, to: to, transport: transport).seconds / 60).rounded(.up))
    }

    /// One start time per stop. `start` is when the day's first leg begins: from the hotel when there
    /// is one, else the first stop's own start.
    static func times(stops: [Stop],
                      start: Date,
                      hotel: CLLocationCoordinate2D?,
                      transport: TripPreferences.Transport,
                      transitMinutes: [String: Int] = [:]) -> [Date] {
        let items = stops.enumerated().map { index, stop -> ScheduleService.AutoItem in
            var travel = 0
            if index > 0 {
                travel = travelMinutes(from: stops[index - 1].coordinate, to: stop.coordinate,
                                       transport: transport, transitMinutes: transitMinutes)
            }
            return ScheduleService.AutoItem(durationMinutes: stop.durationMinutes, travelMinutes: travel)
        }
        var first = start
        if let hotel, let firstStop = stops.first {
            let minutes = travelMinutes(from: hotel, to: firstStop.coordinate,
                                        transport: transport, transitMinutes: transitMinutes)
            first = first.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return ScheduleService.autoSchedule(items: items, start: first)
    }

    /// When the day's first leg should start: the first stop's current time (less the way from the hotel),
    /// else 9:00, and never before you are ready after landing.
    static func suggestedStart(for day: Day) -> Date {
        let calendar = Calendar.current
        let window = day.trip?.window(for: day.date) ?? DayWindow()
        let stops = day.sortedStops
        var start = day.defaultWallClock(hour: 9)
        if let time = stops.first?.plannedTime {
            start = day.combine(time: time)
            if let hotel = window.anchor, let first = stops.first {
                let minutes = travelMinutes(from: hotel, to: first.coordinate, transport: day.trip?.transport ?? .walking)
                start = start.addingTimeInterval(-TimeInterval(minutes * 60))
            }
        }
        if let ready = window.startMinute {
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            if (parts.hour ?? 0) * 60 + (parts.minute ?? 0) < ready {
                start = calendar.date(bySettingHour: ready / 60, minute: ready % 60, second: 0, of: day.date) ?? start
            }
        }
        return start
    }

    /// Re-times a whole day in its current order (an estimate; the Plan's time sheet can also look up
    /// real public transport times).
    @MainActor
    static func adjust(_ day: Day) {
        let stops = day.sortedStops
        guard !stops.isEmpty else { return }
        let window = day.trip?.window(for: day.date) ?? DayWindow()
        let result = times(stops: stops, start: suggestedStart(for: day), hotel: window.anchor,
                           transport: day.trip?.transport ?? .walking)
        for (stop, time) in zip(stops, result) {
            stop.plannedTime = time
        }
    }
}
