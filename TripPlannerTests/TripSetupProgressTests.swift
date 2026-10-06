import XCTest
import SwiftData
@testable import TripPlanner

@MainActor
final class TripSetupProgressTests: XCTestCase {
    private func makeTrip() throws -> (ModelContainer, Trip) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: config)
        let start = Calendar.current.startOfDay(for: Date())
        let trip = Trip(name: "Test", destination: "", startDate: start, endDate: start)
        container.mainContext.insert(trip)
        trip.syncDays()
        return (container, trip)
    }

    func testNewTripHasNothingDone() throws {
        let (container, trip) = try makeTrip()
        _ = container
        XCTAssertEqual(TripSetupProgress.completed(for: trip), 0)
        XCTAssertEqual(TripSetupProgress.steps(for: trip).count, 6)
    }

    func testStepsCompleteAsDataIsAdded() throws {
        let (container, trip) = try makeTrip()
        let context = container.mainContext

        trip.setDestination(name: "Lisbon", coordinate: .init(latitude: 38.7, longitude: -9.1))
        trip.budget = 500
        let item = ChecklistItem(title: "Passport", section: "Documents & money")
        context.insert(item)
        item.trip = trip
        let doc = TripDocument(title: "Flight", fileName: "flight.pdf", kind: .ticket, data: Data([1]))
        context.insert(doc)
        doc.trip = trip

        for kind in [BookingKind.hotel, .arrivalFlight] {
            let booking = Booking(kind: kind, startDate: Date(), endDate: Date())
            context.insert(booking)
            booking.trip = trip
        }

        let day = trip.sortedDays[0]
        for name in ["A", "B", "C"] {
            day.append(Stop(name: name, latitude: 0, longitude: 0))
        }

        let done = Dictionary(uniqueKeysWithValues: TripSetupProgress.steps(for: trip).map { ($0.id, $0.isDone) })
        XCTAssertEqual(done["destination"], true)
        XCTAssertEqual(done["stops"], true)
        XCTAssertEqual(done["bookings"], true)
        XCTAssertEqual(done["budget"], true)
        XCTAssertEqual(done["packing"], true)
        XCTAssertEqual(done["logistics"], true)
    }

    func testTwoStopsAreNotEnough() throws {
        let (container, trip) = try makeTrip()
        _ = container
        let day = trip.sortedDays[0]
        day.append(Stop(name: "A", latitude: 0, longitude: 0))
        day.append(Stop(name: "B", latitude: 0, longitude: 0))
        let stops = TripSetupProgress.steps(for: trip).first { $0.id == "stops" }
        XCTAssertEqual(stops?.isDone, false)
    }
}
