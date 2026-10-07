import XCTest
import CoreLocation
@testable import TripPlanner

final class TransitTests: XCTestCase {
    private func assertEqual(_ a: CLLocationCoordinate2D, _ lat: Double, _ lon: Double, accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.latitude, lat, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.longitude, lon, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Polyline

    func testPolylinePrecision5() {
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(points.count, 3)
        assertEqual(points[0], 38.5, -120.2, accuracy: 1e-5)
        assertEqual(points[1], 40.7, -120.95, accuracy: 1e-5)
        assertEqual(points[2], 43.252, -126.453, accuracy: 1e-5)
    }

    func testPolylinePrecision6() {
        let points = Polyline.decode("wa|yhAntmlP~nKnzDv`^~mzC", precision: 6)
        XCTAssertEqual(points.count, 3)
        assertEqual(points[0], 38.7139, -9.1334, accuracy: 1e-6)
        assertEqual(points[1], 38.7075, -9.1364, accuracy: 1e-6)
        assertEqual(points[2], 38.6916, -9.2160, accuracy: 1e-6)
    }

    func testEmptyPolyline() {
        XCTAssertTrue(Polyline.decode("").isEmpty)
    }

    // MARK: Parsing a Transitous answer

    private func sampleResponse() -> [String: Any] {
        func place(_ name: String, _ lat: Double, _ lon: Double, _ key: String, _ time: String) -> [String: Any] {
            ["name": name, "lat": lat, "lon": lon, key: time]
        }
        return [
            "itineraries": [[
                "duration": 3300,
                "transfers": 1,
                "startTime": "2026-10-09T09:00:00Z",
                "endTime": "2026-10-09T09:55:00Z",
                "legs": [
                    ["mode": "WALK", "duration": 840, "distance": 900.0,
                     "from": place("START", 38.7139, -9.1334, "departure", "2026-10-09T09:00:00Z"),
                     "to": place("Alfândega", 38.7075, -9.1364, "arrival", "2026-10-09T09:14:00Z"),
                     "legGeometry": ["points": "wa|yhAntmlPoK_X", "precision": 6, "length": 2]],
                    ["mode": "BUS", "duration": 1560, "distance": 7000.0,
                     "routeShortName": "728", "headsign": "Algés", "agencyName": "Carris",
                     "from": place("Alfândega", 38.7075, -9.1364, "departure", "2026-10-09T09:20:00Z"),
                     "to": place("Mosteiro Jerónimos", 38.6916, -9.2160, "arrival", "2026-10-09T09:46:00Z"),
                     "intermediateStops": [["name": "A"], ["name": "B"], ["name": "C"]],
                     "legGeometry": ["points": "wa|yhAntmlP~nKnzDv`^~mzC", "precision": 6, "length": 3]],
                    ["mode": "WALK", "duration": 540, "distance": 600.0,
                     "from": place("Mosteiro Jerónimos", 38.6916, -9.2160, "departure", "2026-10-09T09:46:00Z"),
                     "to": place("END", 38.6910, -9.2170, "arrival", "2026-10-09T09:55:00Z")],
                ],
            ]],
        ]
    }

    func testParsesLegsPathsAndNames() throws {
        let itineraries = TransitousService.parse(sampleResponse())
        XCTAssertEqual(itineraries.count, 1)
        let trip = itineraries[0]
        XCTAssertEqual(trip.duration, 3300)
        XCTAssertEqual(trip.transfers, 1)
        XCTAssertEqual(trip.legs.count, 3)

        XCTAssertEqual(trip.legs[0].mode, .walk)
        XCTAssertEqual(trip.legs[0].fromName, "Start")
        XCTAssertEqual(trip.legs[2].toName, "Destination")
        XCTAssertEqual(trip.legs[0].path.count, 2)

        let bus = trip.legs[1]
        XCTAssertEqual(bus.mode, .bus)
        XCTAssertEqual(bus.routeShortName, "728")
        XCTAssertEqual(bus.headsign, "Algés")
        XCTAssertEqual(bus.agencyName, "Carris")
        XCTAssertEqual(bus.stopCount, 3)
        XCTAssertEqual(bus.path.count, 3)
        XCTAssertNil(bus.colorHex)
        XCTAssertNotNil(bus.departure)

        XCTAssertEqual(trip.legs[2].coordinates.count, 2, "a leg without geometry falls back to its two ends")
        XCTAssertEqual(trip.headlineMode, .bus)
        XCTAssertEqual(trip.walkingSeconds, 840 + 540)
    }

    func testSummaryNamesTheLinesAndChanges() throws {
        let trip = try XCTUnwrap(TransitousService.parse(sampleResponse()).first)
        XCTAssertEqual(trip.summary, "Bus 728 · 55 min · 1 change")
    }

    func testSummaryForWalkingOnlyAndDirect() {
        func leg(_ mode: TransitMode, _ name: String?, seconds: Int) -> TransitLeg {
            TransitLeg(mode: mode, fromName: "A", toName: "B",
                       from: TransitPoint(lat: 0, lon: 0), to: TransitPoint(lat: 0, lon: 0),
                       departure: nil, arrival: nil, routeShortName: name, routeLongName: nil, headsign: nil,
                       agencyName: nil, colorHex: nil, distance: 0, duration: seconds, stopCount: 0, path: [])
        }
        let walking = TransitItinerary(duration: 600, transfers: 0, start: nil, end: nil, legs: [leg(.walk, nil, seconds: 600)])
        XCTAssertEqual(walking.summary, "Walk 10 min")

        let direct = TransitItinerary(duration: 1320, transfers: 0, start: nil, end: nil,
                                      legs: [leg(.walk, nil, seconds: 180), leg(.tram, "28", seconds: 1140)])
        XCTAssertEqual(direct.summary, "Tram 28 · 22 min · direct")
    }

    func testModeMapping() {
        XCTAssertEqual(TransitMode(motis: "WALK"), .walk)
        XCTAssertEqual(TransitMode(motis: "SUBWAY"), .subway)
        XCTAssertEqual(TransitMode(motis: "TRAM"), .tram)
        XCTAssertEqual(TransitMode(motis: "BUS"), .bus)
        XCTAssertEqual(TransitMode(motis: "COACH"), .bus)
        XCTAssertEqual(TransitMode(motis: "REGIONAL_RAIL"), .rail)
        XCTAssertEqual(TransitMode(motis: "HIGHSPEED_RAIL"), .rail)
        XCTAssertEqual(TransitMode(motis: "SUBURBAN"), .rail)
        XCTAssertEqual(TransitMode(motis: "FERRY"), .ferry)
        XCTAssertEqual(TransitMode(motis: "FUNICULAR"), .cableCar)
        XCTAssertEqual(TransitMode(motis: "SOMETHING_NEW"), .other)
    }

    @MainActor
    func testALongWalkOnlyAnswerCountsAsNoCoverage() throws {
        func walkOnly(minutes: Int) -> TransitItinerary {
            TransitItinerary(duration: minutes * 60, transfers: 0, start: nil, end: nil, legs: [
                TransitLeg(mode: .walk, fromName: "A", toName: "B", from: TransitPoint(lat: 0, lon: 0),
                           to: TransitPoint(lat: 0, lon: 0), departure: nil, arrival: nil, routeShortName: nil,
                           routeLongName: nil, headsign: nil, agencyName: nil, colorHex: nil, distance: 0,
                           duration: minutes * 60, stopCount: 0, path: []),
            ])
        }
        XCTAssertFalse(TransitRouter.hasUsefulRoute([walkOnly(minutes: 60)]))
        XCTAssertTrue(TransitRouter.hasUsefulRoute([walkOnly(minutes: 12)]))
        XCTAssertTrue(TransitRouter.hasUsefulRoute(TransitousService.parse(sampleResponse())))
        XCTAssertFalse(TransitRouter.hasUsefulRoute([]))
    }

    // MARK: Time

    func testRequestTimeIsUTC() {
        XCTAssertEqual(TransitTime.requestString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
    }

    func testWallClockIsReadInTheDestinationZone() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let wall = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 10, minute: 0))!

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        XCTAssertEqual(calendar.component(.hour, from: TransitTime.instant(wallClock: wall, in: utc)), 10)

        calendar.timeZone = tokyo
        XCTAssertEqual(calendar.component(.hour, from: TransitTime.instant(wallClock: wall, in: tokyo)), 10)
    }

    func testFarFutureDatesUseTheNextSameWeekday() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let far = calendar.date(from: DateComponents(year: 2027, month: 3, day: 10, hour: 10, minute: 30))!

        let result = TransitTime.queryInstant(for: far, now: now, in: utc)

        XCTAssertTrue(result.isTypical)
        XCTAssertEqual(calendar.component(.weekday, from: result.instant), calendar.component(.weekday, from: far))
        XCTAssertEqual(calendar.component(.hour, from: result.instant), 10)
        XCTAssertEqual(calendar.component(.minute, from: result.instant), 30)
        XCTAssertGreaterThan(result.instant, now)
        XCTAssertLessThan(result.instant.timeIntervalSince(now), 9 * 86_400)

        let soon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        let unchanged = TransitTime.queryInstant(for: soon, now: now, in: utc)
        XCTAssertFalse(unchanged.isTypical)
        XCTAssertEqual(unchanged.instant, soon)
    }

    // MARK: Keys

    func testPairKeyIsStableAndDirectional() {
        let a = CLLocationCoordinate2D(latitude: 38.71391, longitude: -9.13341)
        let b = CLLocationCoordinate2D(latitude: 38.69160, longitude: -9.21600)
        XCTAssertEqual(TransitRouter.pairKey(a, b), TransitRouter.pairKey(a, b))
        XCTAssertNotEqual(TransitRouter.pairKey(a, b), TransitRouter.pairKey(b, a))
        XCTAssertEqual(TransitRouter.cacheKey(from: a, to: b, instant: Date(timeIntervalSince1970: 1_000_000), arriveBy: false),
                       TransitRouter.cacheKey(from: a, to: b, instant: Date(timeIntervalSince1970: 1_000_300), arriveBy: false),
                       "times within the same 15 minutes share a cache entry")
        XCTAssertNotEqual(TransitRouter.cacheKey(from: a, to: b, instant: Date(timeIntervalSince1970: 1_000_000), arriveBy: false),
                          TransitRouter.cacheKey(from: a, to: b, instant: Date(timeIntervalSince1970: 1_000_000), arriveBy: true))
    }

    // MARK: Real travel times in the schedule

    func testScheduleUsesRealTravelMinutes() {
        var prefs = TripPreferences()
        prefs.dayStart = .normal
        prefs.transport = .transit
        let here = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)
        let there = CLLocationCoordinate2D(latitude: 38.7201, longitude: -9.1401)   // a few metres away
        let first = PlanCandidate(id: "a", name: "A", coordinate: here, kind: .sights, score: 0.5)
        let second = PlanCandidate(id: "b", name: "B", coordinate: there, kind: .sights, score: 0.5)
        let entries: [PlanEditor.Entry] = [(first, .activity), (second, .activity)]

        let plain = AutoPlanner.schedule(entries, prefs: prefs)
        let real = AutoPlanner.schedule(entries, prefs: prefs, travelOverride: { _, _ in 40 })

        XCTAssertEqual(real[0].startMinute, plain[0].startMinute)
        // 9:30 + 90 min stay + 40 travel + 5 slack = 11:45
        XCTAssertEqual(real[1].startMinute, 11 * 60 + 45)
        XCTAssertGreaterThan(real[1].startMinute, plain[1].startMinute)
    }

    // MARK: How transit works here (Wikivoyage)

    func testPicksThePublicTransportSection() {
        let sections: [[String: Any]] = [
            ["index": "1", "line": "Understand", "level": "2"],
            ["index": "20", "line": "Get around", "level": "2"],
            ["index": "21", "line": "By public transport", "level": "3"],
            ["index": "22", "line": "Fares and tickets", "level": "4"],
            ["index": "28", "line": "By bicycle", "level": "3"],
            ["index": "32", "line": "See", "level": "2"],
        ]
        XCTAssertEqual(TransitGuide.pickSection(sections), "21")
    }

    func testFallsBackToGetAroundAndHandlesMissingOnes() {
        let noTransitSubsection: [[String: Any]] = [
            ["index": 5, "line": "Get around", "level": 2],
            ["index": 6, "line": "By bicycle", "level": 3],
            ["index": 7, "line": "See", "level": 2],
            ["index": 8, "line": "By public transport", "level": 3],   // belongs to another section
        ]
        XCTAssertEqual(TransitGuide.pickSection(noTransitSubsection), "5")
        XCTAssertNil(TransitGuide.pickSection([["index": "1", "line": "See", "level": "2"]]))
    }

    func testHTMLBecomesReadableText() {
        let html = "<p>Buy a <b>Viva Viagem</b> card.</p><ul><li>Metro</li><li>Tram &amp; bus</li></ul><style>x{}</style>"
        let text = TransitGuide.plainText(fromHTML: html)
        XCTAssertTrue(text.contains("Buy a Viva Viagem card."))
        XCTAssertTrue(text.contains("• Metro"))
        XCTAssertTrue(text.contains("Tram & bus"))
        XCTAssertFalse(text.contains("<"))
    }

    func testDestinationParts() {
        XCTAssertEqual(TransitGuide.parts(of: "Lisbon, Portugal").city, "Lisbon")
        XCTAssertEqual(TransitGuide.parts(of: "Lisbon, Portugal").country, "Portugal")
        XCTAssertNil(TransitGuide.parts(of: "Lisbon").country)
    }

    func testNotesRoundTripAsJSON() throws {
        let notes = TransitNotes(tickets: ["Viva Viagem card"], apps: ["Citymapper"], tips: [])
        let data = try JSONEncoder().encode(notes)
        XCTAssertEqual(try JSONDecoder().decode(TransitNotes.self, from: data), notes)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(TransitNotes().isEmpty)
    }
}
