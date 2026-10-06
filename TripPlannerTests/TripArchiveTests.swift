import XCTest
import SwiftData
@testable import TripPlanner

@MainActor
final class TripArchiveTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                           ChecklistItem.self, TripDocument.self, SavedPlace.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testRoundTripKeepsEverything() throws {
        let source = try makeContainer()
        let context = source.mainContext

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let trip = Trip(name: "Lisbon", destination: "Lisbon, Portugal", startDate: start, endDate: end)
        context.insert(trip)
        trip.syncDays()
        trip.setDestination(name: "Lisbon, Portugal", coordinate: .init(latitude: 38.72, longitude: -9.14))
        trip.budget = 800
        trip.currencyCode = "EUR"

        let days = trip.sortedDays
        let stop = Stop(name: "Belém Tower", latitude: 38.69, longitude: -9.21, address: "Lisbon", category: .sight)
        days[0].append(stop)
        stop.plannedTime = Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: days[0].date)
        stop.notes = "Tickets online"
        stop.estimatedCost = 12
        days[0].append(Stop(name: "Time Out Market", latitude: 38.70, longitude: -9.14, category: .food))

        let expense = Expense(title: "Lunch", amount: 18.5, currencyCode: "EUR", category: .food, date: start)
        context.insert(expense)
        expense.trip = trip
        let item = ChecklistItem(title: "Passport", section: "Documents & money", order: 0)
        context.insert(item)
        item.isDone = true
        item.trip = trip
        let saved = SavedPlace(name: "LX Factory", latitude: 38.70, longitude: -9.18)
        context.insert(saved)
        saved.trip = trip
        let document = TripDocument(title: "Flight", fileName: "flight.pdf", kind: .ticket, data: Data([1, 2, 3]))
        context.insert(document)
        document.trip = trip

        let data = try TripArchiver.encode(TripArchiver.archive([trip], includeDocuments: true))

        let target = try makeContainer()
        let restored = TripArchiver.insert(try TripArchiver.decode(data), into: target.mainContext)

        XCTAssertEqual(restored.count, 1)
        let copy = restored[0]
        XCTAssertEqual(copy.name, "Lisbon")
        XCTAssertEqual(copy.budget, 800)
        XCTAssertTrue(copy.hasDestinationCoordinate)
        XCTAssertEqual(copy.sortedDays.count, 2)
        XCTAssertEqual(copy.sortedDays[0].sortedStops.map(\.name), ["Belém Tower", "Time Out Market"])
        XCTAssertEqual(copy.sortedDays[0].sortedStops[0].notes, "Tickets online")
        XCTAssertEqual(copy.sortedDays[0].sortedStops[0].estimatedCost, 12)
        XCTAssertNotNil(copy.sortedDays[0].sortedStops[0].plannedTime)
        XCTAssertEqual(copy.expenses.count, 1)
        XCTAssertEqual(copy.checklist.first?.isDone, true)
        XCTAssertEqual(copy.savedPlaces.count, 1)
        XCTAssertEqual(copy.documents.first?.data, Data([1, 2, 3]))
    }

    func testDocumentsAreLeftOutWhenNotRequested() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Calendar.current.startOfDay(for: Date())
        let trip = Trip(name: "T", destination: "", startDate: start, endDate: start)
        context.insert(trip)
        let document = TripDocument(title: "Flight", fileName: "flight.pdf", kind: .ticket, data: Data([9]))
        context.insert(document)
        document.trip = trip

        let archive = TripArchiver.archive([trip], includeDocuments: false)
        XCTAssertTrue(archive.trips[0].documents.isEmpty)
    }

    func testRejectsGarbageAndNewerVersions() throws {
        XCTAssertThrowsError(try TripArchiver.decode(Data("not json".utf8)))

        var future = TripArchive(trips: [])
        future.version = TripArchive.currentVersion + 1
        let data = try TripArchiver.encode(future)
        XCTAssertThrowsError(try TripArchiver.decode(data))
    }
}
