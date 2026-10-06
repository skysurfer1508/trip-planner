import Foundation
import SwiftData
import CoreLocation
import MapKit

@Model
final class Trip {
    var name: String = ""
    var destination: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var destinationLatitude: Double = 0
    var destinationLongitude: Double = 0
    var hasDestinationCoordinate: Bool = false
    var budget: Double = 0
    var currencyCode: String = "EUR"
    /// Encoded `TripPreferences` from the last Auto plan, to pre-fill the questions.
    var planPreferences: Data?
    @Relationship(deleteRule: .cascade, inverse: \Day.trip) var days: [Day] = []
    @Relationship(deleteRule: .cascade, inverse: \Expense.trip) var expenses: [Expense] = []
    @Relationship(deleteRule: .cascade, inverse: \ChecklistItem.trip) var checklist: [ChecklistItem] = []
    @Relationship(deleteRule: .cascade, inverse: \TripDocument.trip) var documents: [TripDocument] = []
    @Relationship(deleteRule: .cascade, inverse: \SavedPlace.trip) var savedPlaces: [SavedPlace] = []

    init(name: String, destination: String, startDate: Date, endDate: Date) {
        self.name = name
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
        self.currencyCode = Locale.current.currency?.identifier ?? "EUR"
    }

    var sortedDays: [Day] {
        days.sorted { $0.date < $1.date }
    }

    var isActiveToday: Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.startOfDay(for: startDate) <= today && today <= calendar.startOfDay(for: endDate)
    }

    var isPast: Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: endDate) < calendar.startOfDay(for: Date())
    }

    var todayDay: Day? {
        days.first { Calendar.current.isDateInToday($0.date) }
    }

    /// "in 12 days", "Day 2 of 5" or "Ended", for the trip list and hub.
    var statusText: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        if today < start {
            let n = calendar.dateComponents([.day], from: today, to: start).day ?? 0
            return n == 1 ? "Starts tomorrow" : "In \(n) days"
        }
        if today <= end {
            let day = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            let total = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            return "Day \(day) of \(total)"
        }
        return "Ended"
    }

    // MARK: Destination

    var destinationCoordinate: CLLocationCoordinate2D? {
        hasDestinationCoordinate
            ? CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
            : nil
    }

    /// Region around the destination, used to bias place search.
    var searchRegion: MKCoordinateRegion? {
        guard let center = destinationCoordinate else { return nil }
        return MKCoordinateRegion(center: center, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
    }

    func setDestination(name: String, coordinate: CLLocationCoordinate2D?) {
        destination = name
        if let coordinate {
            destinationLatitude = coordinate.latitude
            destinationLongitude = coordinate.longitude
            hasDestinationCoordinate = true
        } else {
            hasDestinationCoordinate = false
        }
    }

    /// Best known coordinate of the trip: the destination, else the first planned stop.
    var anyCoordinate: CLLocationCoordinate2D? {
        destinationCoordinate ?? sortedDays.lazy.flatMap { $0.sortedStops }.first?.coordinate
    }

    // MARK: Days

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
