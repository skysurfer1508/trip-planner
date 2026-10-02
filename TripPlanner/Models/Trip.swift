import Foundation
import SwiftData
import CoreLocation

@Model
final class Trip {
    var name: String = ""
    var destination: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Day.trip) var days: [Day] = []

    init(name: String, destination: String, startDate: Date, endDate: Date) {
        self.name = name
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
    }

    var sortedDays: [Day] {
        days.sorted { $0.date < $1.date }
    }

    var isActiveToday: Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.startOfDay(for: startDate) <= today && today <= calendar.startOfDay(for: endDate)
    }

    var todayDay: Day? {
        days.first { Calendar.current.isDateInToday($0.date) }
    }

    /// Any known coordinate of the trip, used to look up weather.
    var anyCoordinate: CLLocationCoordinate2D? {
        sortedDays.lazy.flatMap { $0.sortedStops }.first?.coordinate
    }

    /// Makes `days` match the start/end dates. Days that still have stops are never deleted.
    /// The trip has to be inserted into a context before calling this.
    func syncDays() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = max(calendar.startOfDay(for: endDate), start)

        var wanted: [Date] = []
        var cursor = start
        while cursor <= end && wanted.count < 120 {
            wanted.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        for day in Array(days) where !wanted.contains(calendar.startOfDay(for: day.date)) && day.stops.isEmpty {
            modelContext?.delete(day)
        }

        let existing = Set(days.map { calendar.startOfDay(for: $0.date) })
        for date in wanted where !existing.contains(date) {
            let day = Day(date: date)
            modelContext?.insert(day)
            days.append(day)
        }
    }
}
