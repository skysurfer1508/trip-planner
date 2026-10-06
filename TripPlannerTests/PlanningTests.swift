import XCTest
import SwiftData
@testable import TripPlanner

@MainActor
final class PlanningTests: XCTestCase {
    private func makeTrip() throws -> (ModelContainer, Trip) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: config)
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let trip = Trip(name: "Test", destination: "Lisbon", startDate: start, endDate: end)
        container.mainContext.insert(trip)
        trip.syncDays()
        return (container, trip)
    }

    func testMoveStopToAnotherDayKeepsTimeOfDay() throws {
        let (container, trip) = try makeTrip()
        _ = container
        let days = trip.sortedDays
        XCTAssertEqual(days.count, 2)

        let stop = Stop(name: "Museum", latitude: 38.7, longitude: -9.1)
        days[0].append(stop)
        stop.plannedTime = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: days[0].date)

        days[0].move(stop, to: days[1])

        XCTAssertEqual(days[0].stops.count, 0)
        XCTAssertEqual(days[1].stops.count, 1)
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: stop.plannedTime!)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.day, Calendar.current.component(.day, from: days[1].date))
    }

    func testDuplicatePutsCopyRightAfterOriginal() throws {
        let (container, trip) = try makeTrip()
        _ = container
        let day = trip.sortedDays[0]
        let a = Stop(name: "A", latitude: 0, longitude: 0)
        let b = Stop(name: "B", latitude: 0, longitude: 0)
        day.append(a)
        day.append(b)

        day.duplicate(a)

        XCTAssertEqual(day.sortedStops.map(\.name), ["A", "A", "B"])
    }

    func testCopyDayCopiesAllStopsAndResetsDone() throws {
        let (container, trip) = try makeTrip()
        _ = container
        let days = trip.sortedDays
        let stop = Stop(name: "A", latitude: 0, longitude: 0)
        days[0].append(stop)
        stop.isDone = true

        days[0].copyStops(to: days[1])

        XCTAssertEqual(days[0].stops.count, 1)
        XCTAssertEqual(days[1].stops.count, 1)
        XCTAssertFalse(days[1].stops[0].isDone)
    }
}
