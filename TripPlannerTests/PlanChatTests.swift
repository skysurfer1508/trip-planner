import XCTest
import SwiftData
import CoreLocation
@testable import TripPlanner

@MainActor
final class PlanChatTests: XCTestCase {
    /// An in-memory store only lives as long as its container: keep every one until the test is over.
    private var containers: [ModelContainer] = []

    private func makeTrip(days: Int = 3) throws -> (ModelContainer, Trip) {
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
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
        _ = stop("Land · W6 1386", 0, on: days[0])   // the arrival stop made from a booking is not one to change
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

@MainActor
final class AuditFixTests: XCTestCase {
    private var containers: [ModelContainer] = []

    private func makeTrip() throws -> (ModelContainer, Trip) {
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        let start = Calendar.current.startOfDay(for: Date())
        let trip = Trip(name: "T", destination: "Warsaw", startDate: start, endDate: start)
        container.mainContext.insert(trip)
        trip.syncDays()
        return (container, trip)
    }

    func testRemoveTakesTheStopOutAtOnceAndKeepsTheOrder() throws {
        let (_, trip) = try makeTrip()
        let day = trip.sortedDays[0]
        let a = Stop(name: "A", latitude: 0, longitude: 0); day.append(a)
        let b = Stop(name: "B", latitude: 0, longitude: 0); day.append(b)
        let c = Stop(name: "C", latitude: 0, longitude: 0); day.append(c)
        day.remove(b)
        XCTAssertEqual(day.sortedStops.map(\.name), ["A", "C"], "no ghost row for B")
        XCTAssertEqual(day.sortedStops.map(\.order), [0, 1])
    }

    func testTheDayStartsAtItsEarliestTimeWhateverTheOrder() throws {
        let (_, trip) = try makeTrip()
        let day = trip.sortedDays[0]
        let evening = Stop(name: "Evening", latitude: 0, longitude: 0); day.append(evening)
        evening.plannedTime = WallClock.date(on: day.date, minute: 19 * 60)
        let morning = Stop(name: "Morning", latitude: 0, longitude: 0.001); day.append(morning)
        morning.plannedTime = WallClock.date(on: day.date, minute: 10 * 60)
        let start = TimeAdjuster.suggestedStart(for: day)
        XCTAssertEqual(WallClock.minute(of: start), 10 * 60, "dragging the evening stop to the top must not move the day to the evening")
    }

    func testHolidayCacheGivesTheSameListForTheSameText() {
        let json = #"[{"date":"2026-11-11","name":"Independence Day","localName":"Święto Niepodległości","isRegional":false}]"#
        XCTAssertEqual(HolidayCache.list(for: json).map(\.date), ["2026-11-11"])
        XCTAssertEqual(HolidayCache.list(for: json).count, 1)
        XCTAssertTrue(HolidayCache.list(for: "not json").isEmpty)
    }
}

final class HoursMatchingTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 50.054, longitude: 19.935)

    private func element(_ name: String, _ hours: String, dLat: Double = 0.00002) -> [String: Any] {
        ["tags": ["name": name, "opening_hours": hours], "lat": here.latitude + dLat, "lon": here.longitude]
    }

    func testAShopWithAMatchingStartOfNameIsNotTheSight() {
        XCTAssertFalse(OpeningHoursService.namesMatch("Wawel Castle Gift Shop", "Wawel Castle"))
        XCTAssertTrue(OpeningHoursService.namesMatch("Belém Tower", "Tower of Belém"))
        XCTAssertTrue(OpeningHoursService.namesMatch("Złote Tarasy", "Zlote Tarasy"))
    }

    func testASightGetsHoursOnlyFromItsOwnEntry() {
        let elements = [element("Wawel Castle Gift Shop", "Mo-Su 09:00-17:00"), element("Wawel Castle", "Tu-Su 09:30-16:00")]
        let match = OpeningHoursService.pickMatch(from: elements, name: "Wawel Castle", coordinate: here, category: .sight)
        XCTAssertEqual(match?.hours, "Tu-Su 09:30-16:00")
        XCTAssertEqual(match?.source, "Wawel Castle")
        XCTAssertEqual(match?.byName, true)

        let onlyTheShop = OpeningHoursService.pickMatch(from: [element("Wawel Castle Gift Shop", "Mo-Su 09:00-17:00")],
                                                        name: "Wawel Castle", coordinate: here, category: .sight)
        XCTAssertNil(onlyTheShop)
    }

    func testOnlyShopsAndRestaurantsMayUseTheNearestEntry() {
        let unnamed: [[String: Any]] = [["tags": ["opening_hours": "Mo-Fr 08:00-20:00"], "lat": here.latitude + 0.00003, "lon": here.longitude]]
        for category in [StopCategory.sight, .other, .hotel] {
            XCTAssertNil(OpeningHoursService.pickMatch(from: unnamed, name: "Anything", coordinate: here, category: category), "\(category)")
        }
        for category in [StopCategory.food, .cafe, .nightlife] {
            XCTAssertEqual(OpeningHoursService.pickMatch(from: unnamed, name: "Anything", coordinate: here, category: category)?.hours,
                           "Mo-Fr 08:00-20:00", "\(category)")
        }
    }

    func testHoursMarkedWrongAreNotOfferedAgain() {
        let elements = [element("Old Town Market", "Mo-Su 08:00-14:00")]
        XCTAssertNil(OpeningHoursService.pickMatch(from: elements, name: "Old Town Market", coordinate: here,
                                                   category: .food, rejectedHours: "Mo-Su 08:00-14:00"))
        XCTAssertNotNil(OpeningHoursService.pickMatch(from: elements, name: "Old Town Market", coordinate: here, category: .food))
    }

    func testClockPastMidnight() {
        XCTAssertEqual(OpeningHours.clock(1560), "02:00")
        XCTAssertEqual(OpeningHours.clock(1440), "24:00")
        XCTAssertEqual(OpeningHours.clock(17 * 60 + 30), "17:30")
    }

    func testParsedHoursAreReusedAndStayCorrect() {
        let first = OpeningHours.parse("Tu-Su 10:00-17:00")
        let second = OpeningHours.parse("Tu-Su 10:00-17:00")
        XCTAssertEqual(first?.rules.count, second?.rules.count)
        XCTAssertNil(OpeningHours.parse("sunrise-sunset"))
        XCTAssertNil(OpeningHours.parse("sunrise-sunset"), "an unsupported text stays unsupported when read from the cache")
    }
}

final class OwnPlacesSafetyTests: XCTestCase {
    func testTwoOfTheTravellersPlacesWithTheSameNameAreBothKept() {
        let spot = CLLocationCoordinate2D(latitude: 52.23, longitude: 21.01)
        var one = PlanCandidate(id: "a", name: "Old Town", coordinate: spot, kind: .sights, score: 1)
        one.isMustSee = true
        var two = PlanCandidate(id: "b", name: "Old Town", coordinate: spot, kind: .sights, score: 1)
        two.isMustSee = true
        let popular = PlanCandidate(id: "c", name: "Old Town Square", coordinate: spot, kind: .sights, score: 0.9)
        let result = AutoPlanner.dedupe([popular, one, two])
        XCTAssertEqual(Set(result.map(\.id)), ["a", "b"], "the popular lookalike goes, the traveller's own never do")
    }
}

final class EntranceStorageTests: XCTestCase {
    func testAnswersWithCoordinatesBecomeEntrances() {
        // `out tags center` keeps the coordinates of nodes; the answer looks like this.
        let json: [String: Any] = ["elements": [
            ["type": "node", "id": 1, "lat": 52.23, "lon": 21.011, "tags": ["railway": "subway_entrance", "ref": "5"]],
        ]]
        XCTAssertEqual(TransitEntrances.parseOverpass(json).first?.name, "Exit 5")
    }

    func testEmptyAnswersAreKeptForAShorterTime() {
        XCTAssertLessThan(EntranceDiskCache.maxAge(isEmpty: true), EntranceDiskCache.maxAge(isEmpty: false))
    }

    func testEntrancesSurviveTheDiskRoundTrip() {
        let key = "test-\(UUID().uuidString)"
        let door = StationEntrance(name: "Exit 1", latitude: 52.2, longitude: 21.0, source: "OpenStreetMap", isEntrance: true)
        EntranceDiskCache.write(key, [door])
        XCTAssertEqual(EntranceDiskCache.read(key), [door])
        XCTAssertNil(EntranceDiskCache.read(key, now: Date().addingTimeInterval(61 * 86_400)), "too old")
        XCTAssertNil(EntranceDiskCache.read("missing-\(UUID().uuidString)"))
    }
}

final class WikidataHoursTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 52.2478, longitude: 21.0148)

    func testWikidataIDsAreRecognised() {
        XCTAssertTrue(OpeningHoursService.isWikidataID("Q1016845"))
        XCTAssertFalse(OpeningHoursService.isWikidataID(""))
        XCTAssertFalse(OpeningHoursService.isWikidataID("Q12; out;"), "nothing that could change the query")
        XCTAssertFalse(OpeningHoursService.isWikidataID("q12"))
    }

    func testNothingMappedFallsBackToNames() {
        XCTAssertEqual(OpeningHoursService.exact(from: [], coordinate: here), .notMapped)
    }

    func testAMappedPlaceWithoutHoursStaysWithoutHours() {
        // The castle itself is mapped (in Polish) but has no hours: the gift shop next door must not lend its own.
        let castle: [[String: Any]] = [["tags": ["name": "Zamek Królewski w Warszawie", "tourism": "museum", "wikidata": "Q1016845"],
                                         "lat": 52.2478, "lon": 21.0148]]
        XCTAssertEqual(OpeningHoursService.exact(from: castle, coordinate: here), .noHours)
    }

    func testTheEntryWithHoursWinsAndBringsItsWebsite() {
        let elements: [[String: Any]] = [
            ["tags": ["name": "Museum", "wikidata": "Q1"], "lat": 52.2490, "lon": 21.0148],
            ["tags": ["name": "Museum", "opening_hours": "Tu-Su 10:00-18:00", "website": "https://example.org"],
             "center": ["lat": 52.2479, "lon": 21.0149]],
        ]
        guard case .hours(let match) = OpeningHoursService.exact(from: elements, coordinate: here) else {
            return XCTFail("expected hours")
        }
        XCTAssertEqual(match.hours, "Tu-Su 10:00-18:00")
        XCTAssertEqual(match.website, "https://example.org")
        XCTAssertTrue(match.byName)
    }

    func testRejectedHoursAreSkipped() {
        let elements: [[String: Any]] = [["tags": ["name": "Museum", "opening_hours": "Mo-Su 09:00-17:00"], "lat": 52.2478, "lon": 21.0148]]
        XCTAssertEqual(OpeningHoursService.exact(from: elements, coordinate: here, rejectedHours: "Mo-Su 09:00-17:00"), .noHours)
    }
}

@MainActor
final class CalendarExportTests: XCTestCase {
    func testEscapingAndFolding() {
        XCTAssertEqual(CalendarExport.escape("Tea, cake; and a \\ walk\nthen home"), "Tea\\, cake\\; and a \\\\ walk\\nthen home")
        let long = String(repeating: "a", count: 200)
        let lines = CalendarExport.fold("DESCRIPTION:" + long)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 75 })
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix(" ") })
        XCTAssertEqual(lines.map { $0.hasPrefix(" ") ? String($0.dropFirst()) : $0 }.joined(), "DESCRIPTION:" + long)
        // A multi-byte character is never cut in half.
        let polish = CalendarExport.fold("SUMMARY:" + String(repeating: "ł", count: 80))
        XCTAssertTrue(polish.allSatisfy { $0.utf8.count <= 75 && String(validatingUTF8: Array($0.utf8CString)) != nil })
    }

    func testIDsAreStableAndFormatIsUTC() {
        XCTAssertEqual(CalendarExport.uid(for: "a"), CalendarExport.uid(for: "a"))
        XCTAssertNotEqual(CalendarExport.uid(for: "a"), CalendarExport.uid(for: "b"))
        XCTAssertTrue(CalendarExport.uid(for: "a").hasSuffix("@tripplanner"))
        XCTAssertEqual(CalendarExport.utc(Date(timeIntervalSince1970: 1_800_000_000)), "20270115T080000Z")
    }

    func testIcsTextHasWhatACalendarNeeds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEvent(key: "k", title: "Royal Castle, Warsaw", start: start, end: start.addingTimeInterval(3_600),
                                  location: "Plac Zamkowy 4", latitude: 52.2478, longitude: 21.0148,
                                  notes: "Tickets\nonline", url: "https://example.org", alarmMinutes: 30)
        let text = CalendarExport.ics(events: [event], calendarName: "Trip", now: start)
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(text.hasSuffix("END:VCALENDAR\r\n"))
        for expected in ["DTSTART:20270115T080000Z", "DTEND:20270115T090000Z", "SUMMARY:Royal Castle\\, Warsaw",
                         "LOCATION:Plac Zamkowy 4", "GEO:52.2478;21.0148", "DESCRIPTION:Tickets\\nonline",
                         "TRIGGER:-PT30M", "URL:https://example.org"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertEqual(text.components(separatedBy: "BEGIN:VEVENT").count, 2)
    }

    func testStopsAndFlightsBecomeEventsAtDestinationTime() throws {
        let container = try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self, ChecklistItem.self,
                                           TripDocument.self, SavedPlace.self, Booking.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 14
        let start = Calendar.current.date(from: parts)!
        let trip = Trip(name: "Warsaw", destination: "Warsaw", startDate: start, endDate: start)
        container.mainContext.insert(trip)
        trip.syncDays()
        trip.timeZoneID = "Europe/Warsaw"
        let day = trip.sortedDays[0]
        let stop = Stop(name: "Royal Castle", latitude: 52.2478, longitude: 21.0148, address: "Plac Zamkowy 4")
        day.append(stop)
        stop.plannedTime = WallClock.date(on: day.date, minute: 10 * 60)
        stop.durationMinutes = 90
        stop.website = "https://zamek-krolewski.pl"

        withExtendedLifetime(container) {}
        let events = CalendarExport.events(for: trip)
        let castle = try XCTUnwrap(events.first { $0.title == "Royal Castle" })
        // 10:00 in Warsaw (summer time, UTC+2) is 08:00 UTC, whatever the phone's own zone.
        XCTAssertEqual(CalendarExport.utc(castle.start), "20261014T080000Z")
        XCTAssertEqual(castle.end.timeIntervalSince(castle.start), 90 * 60)
        XCTAssertEqual(castle.location, "Plac Zamkowy 4")
        XCTAssertEqual(castle.url, "https://zamek-krolewski.pl")
        XCTAssertEqual(castle.alarmMinutes, 30)
        // The same trip gives the same ids again.
        XCTAssertEqual(CalendarExport.events(for: trip).map(\.key), events.map(\.key))
        withExtendedLifetime(container) {}
    }
}
