import XCTest
import SwiftData
import CoreLocation
@testable import TripPlanner

@MainActor
final class PlanChatTests: XCTestCase {
    private func makeTrip(days: Int = 3) throws -> (ModelContainer, Trip) {
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: days - 1, to: start)!
        let trip = Trip(name: "Warsaw", destination: "Warsaw", startDate: start, endDate: end)
        container.mainContext.insert(trip)
        trip.syncDays()
        trip.setDestination(name: "Warsaw", coordinate: .init(latitude: 52.2297, longitude: 21.0122))
        return (container, trip)
    }

    private func stop(_ name: String, _ east: Double, minute: Int? = nil, on day: Day) -> Stop {
        let value = Stop(name: name, latitude: 52.2297, longitude: 21.0122 + east, category: .sight)
        day.append(value)
        if let minute {
            value.plannedTime = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date)
        }
        return value
    }

    private func minute(_ stop: Stop) -> Int? {
        guard let time = stop.plannedTime else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Parsing

    func testAnswerIsParsed() {
        let json: [String: Any] = ["summary": "Swapped.", "edits": [
            ["action": "swap_days", "day": "1", "otherDay": "2"],
            ["action": "shift_day", "day": "", "time": "+60"],
            ["action": ""],
        ]]
        let response = PlanChatJSON.parse(json)
        XCTAssertEqual(response.commands.count, 2)
        XCTAssertEqual(response.commands[0].day, 1)
        XCTAssertEqual(response.commands[0].otherDay, 2)
        XCTAssertNil(response.commands[1].day)
        XCTAssertEqual(response.commands[1].time, "+60")
    }

    // MARK: Times

    func testTimesFollowTheOrderWithTravelInBetween() {
        let a = Stop(name: "A", latitude: 52.2297, longitude: 21.0122)
        let b = Stop(name: "B", latitude: 52.2297, longitude: 21.0122 + 0.03)   // about 2 km
        a.durationMinutes = 60
        b.durationMinutes = 60
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let walking = TimeAdjuster.times(stops: [a, b], start: start, hotel: nil, transport: .walking)
        let driving = TimeAdjuster.times(stops: [a, b], start: start, hotel: nil, transport: .car)
        XCTAssertEqual(walking[0], start)
        XCTAssertGreaterThan(walking[1].timeIntervalSince(walking[0]), 60 * 60 + 20 * 60, "an hour plus a long walk")
        XCTAssertLessThan(driving[1].timeIntervalSince(driving[0]), walking[1].timeIntervalSince(walking[0]))
    }

    func testTheWayFromTheHotelIsAddedToTheFirstStop() {
        let first = Stop(name: "A", latitude: 52.2297, longitude: 21.0122 + 0.03)
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let hotel = CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122)
        let times = TimeAdjuster.times(stops: [first], start: start, hotel: hotel, transport: .walking)
        XCTAssertGreaterThan(times[0], start)
    }

    func testAdjustKeepsTheFirstStopsTime() throws {
        let (_, trip) = try makeTrip(days: 1)
        let day = trip.sortedDays[0]
        let a = stop("A", 0, minute: 10 * 60, on: day)
        let b = stop("B", 0.002, minute: 10 * 60, on: day)     // both at 10:00: overlapping
        TimeAdjuster.adjust(day)
        XCTAssertEqual(minute(a), 10 * 60)
        XCTAssertGreaterThanOrEqual(minute(b) ?? 0, 10 * 60 + 60 + 5)
    }

    // MARK: Edits

    func testMoveRemoveAndSetTime() throws {
        let (_, trip) = try makeTrip()
        let days = trip.sortedDays
        let a = stop("A", 0, minute: 600, on: days[0])
        let b = stop("B", 0.01, minute: 700, on: days[0])
        let c = stop("C", 0.02, on: days[1])
        let aliases = ["s1": a, "s2": b, "s3": c]

        let outcome = PlanChatApplier.apply([
            PlanChatCommand(action: "move", stop: "s1", day: 2),
            PlanChatCommand(action: "remove", stop: "s2"),
            PlanChatCommand(action: "set_time", stop: "s3", time: "15:30"),
        ], trip: trip, stops: aliases, places: [:])

        XCTAssertEqual(outcome.changes.count, 3)
        XCTAssertTrue(days[0].stops.isEmpty)
        XCTAssertEqual(Set(days[1].stops.map(\.name)), ["A", "C"])
        XCTAssertEqual(minute(c), 15 * 60 + 30)
        XCTAssertTrue(days[1].sortedStops.first?.name == "A", "A (10:00) now comes before C (15:30)")
    }

    func testUnknownIdsAreIgnored() throws {
        let (_, trip) = try makeTrip()
        _ = stop("A", 0, on: trip.sortedDays[0])
        let outcome = PlanChatApplier.apply([PlanChatCommand(action: "remove", stop: "s99"),
                                             PlanChatCommand(action: "add", place: "p9", day: 1)],
                                            trip: trip, stops: [:], places: [:])
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(outcome.notes.count, 2)
        XCTAssertEqual(trip.sortedDays[0].stops.count, 1)
    }

    func testSwapDaysAndShift() throws {
        let (_, trip) = try makeTrip()
        let days = trip.sortedDays
        let a = stop("A", 0, minute: 600, on: days[0])
        let b = stop("B", 0.01, minute: 660, on: days[1])
        let outcome = PlanChatApplier.apply([PlanChatCommand(action: "swap_days", day: 1, otherDay: 2),
                                             PlanChatCommand(action: "shift_day", day: 0, time: "+60")],
                                            trip: trip, stops: ["s1": a, "s2": b], places: [:])
        XCTAssertEqual(outcome.changes.count, 2)
        XCTAssertEqual(days[0].stops.map(\.name), ["B"])
        XCTAssertEqual(days[1].stops.map(\.name), ["A"])
        XCTAssertEqual(minute(a), 11 * 60, "10:00 shifted by 60 minutes")
    }

    func testAddAndReplaceUseRealPlaces() throws {
        let (_, trip) = try makeTrip()
        let days = trip.sortedDays
        let old = stop("Old", 0, minute: 600, on: days[0])
        var cafe = PlanCandidate(id: "c", name: "Cafe Nowy", coordinate: .init(latitude: 52.23, longitude: 21.01),
                                 kind: .cafe, score: 0.5)
        cafe.address = "Warsaw"
        let outcome = PlanChatApplier.apply([PlanChatCommand(action: "add", place: "p1", after: "first", day: 1, time: "09:00"),
                                             PlanChatCommand(action: "replace", stop: "s1", place: "p1")],
                                            trip: trip, stops: ["s1": old], places: ["p1": cafe])
        XCTAssertTrue(outcome.changed)
        XCTAssertFalse(days[0].stops.contains { $0.name == "Old" })
        XCTAssertEqual(days[0].stops.filter { $0.name == "Cafe Nowy" }.count, 2)
        XCTAssertEqual(days[0].stops.first { $0.name == "Cafe Nowy" }?.category, .cafe)
    }

    func testUndoPutsTheOldPlanBack() throws {
        let (_, trip) = try makeTrip()
        let days = trip.sortedDays
        let a = stop("A", 0, minute: 600, on: days[0])
        a.notes = "Book ahead"
        _ = stop("B", 0.01, minute: 700, on: days[0])

        let snapshot = TripSnapshot.capture(trip)
        _ = PlanChatApplier.apply([PlanChatCommand(action: "remove", stop: "s1"),
                                   PlanChatCommand(action: "move", stop: "s2", day: 3)],
                                  trip: trip, stops: ["s1": a, "s2": days[0].stops.first { $0.name == "B" }!], places: [:])
        XCTAssertEqual(days[0].stops.count, 0)

        snapshot.restore(into: trip)
        XCTAssertEqual(days[0].sortedStops.map(\.name), ["A", "B"])
        XCTAssertEqual(days[0].sortedStops.first?.notes, "Book ahead")
        XCTAssertEqual(days[2].stops.count, 0)
    }

    func testRequestListsStopsAndRealPlacesOnly() throws {
        let (_, trip) = try makeTrip(days: 2)
        let days = trip.sortedDays
        _ = stop("Old Town", 0, minute: 600, on: days[0])
        _ = stop("Land W6 1386", 0, on: days[0])   // an arrival entry is not a stop to change
        let pool = [PlanCandidate(id: "a", name: "Old Town", coordinate: .init(latitude: 52.2, longitude: 21.0), kind: .sights, score: 1),
                    PlanCandidate(id: "b", name: "Royal Castle", coordinate: .init(latitude: 52.248, longitude: 21.015), kind: .sights, score: 0.9)]
        let prepared = PlanChatService.prepare(instruction: "move things", trip: trip, pool: pool)
        XCTAssertEqual(prepared.request.days.count, 2)
        XCTAssertEqual(prepared.request.days[0].stops.map(\.name), ["Old Town"])
        XCTAssertEqual(prepared.request.places.map(\.name), ["Royal Castle"], "places already in the plan are not offered")
        XCTAssertEqual(prepared.stops["s1"]?.name, "Old Town")
        XCTAssertEqual(prepared.places["p1"]?.id, "b")
    }
}

final class GeminiCheckTests: XCTestCase {
    func testErrorsAreExplainedInPlainLanguage() {
        XCTAssertTrue(GeminiAI.explain(AIError.api("API key not valid. Please pass a valid API key.")).contains("rejected this key"))
        XCTAssertTrue(GeminiAI.explain(AIError.rateLimited).contains("free limit"))
        XCTAssertTrue(GeminiAI.explain(URLError(.notConnectedToInternet)).contains("No internet"))
        XCTAssertTrue(GeminiAI.explain(URLError(.timedOut)).contains("in time"))
        XCTAssertTrue(GeminiAI.explain(AIError.api("models/gemini-x is not found for API version v1beta")).contains("wasn't found"))
        XCTAssertTrue(GeminiAI.explain(AIError.api("something odd")).contains("something odd"))
    }
}
