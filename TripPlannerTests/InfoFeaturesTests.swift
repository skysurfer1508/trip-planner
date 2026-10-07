import XCTest
import CoreLocation
@testable import TripPlanner

final class OpeningHoursTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 2026-10-05 is a Monday; 2026-06-02 is a Tuesday.
    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func verdict(_ rules: String, _ when: Date, minutes: Int = 60,
                         holiday: Set<String> = []) throws -> OpeningHours.Verdict {
        let hours = try XCTUnwrap(OpeningHours.parse(rules), "should parse: \(rules)")
        return hours.verdict(visitAt: when, minutes: minutes,
                             isHoliday: { holiday.contains(PublicHolidays.key($0, calendar: self.calendar)) },
                             calendar: calendar)
    }

    func testWeekdaysOnly() throws {
        XCTAssertEqual(try verdict("Mo-Fr 09:00-17:00", date(10, 6, 10)), .open)
        XCTAssertEqual(try verdict("Mo-Fr 09:00-17:00", date(10, 10, 10)), .closed("Closed on Saturdays"))
        XCTAssertEqual(try verdict("Mo-Fr 09:00-17:00", date(10, 5, 18)), .closed("Closed after 17:00"))
        XCTAssertEqual(try verdict("Mo-Fr 09:00-17:00", date(10, 5, 7)), .opensLater(9 * 60))
    }

    func testSeasonalRulesLikeTorreDeBelem() throws {
        let torre = "Oct-Apr: Tu-Su 10:00-17:30; May-Sep: Tu-Su 10:00-18:30"
        XCTAssertEqual(try verdict(torre, date(10, 6, 16)), .open)
        XCTAssertEqual(try verdict(torre, date(10, 6, 17), minutes: 90), .closesEarly(17 * 60 + 30))
        XCTAssertEqual(try verdict(torre, date(10, 5, 11)), .closed("Closed on Mondays"))
        XCTAssertEqual(try verdict(torre, date(6, 2, 18), minutes: 30), .open, "summer hours run until 18:30")
    }

    func testAMonthTheRulesDoNotCoverIsUnknown() throws {
        XCTAssertEqual(try verdict("Jun-Aug Mo-Su 10:00-18:00", date(10, 6, 12)), .unknown)
        XCTAssertEqual(try verdict("Jun-Aug Mo-Su 10:00-18:00", date(6, 2, 12)), .open)
    }

    func testLunchBreak() throws {
        XCTAssertEqual(try verdict("Mo-Su 09:00-12:00,14:00-18:00", date(10, 6, 13)), .opensLater(14 * 60))
        XCTAssertEqual(try verdict("Mo-Su 09:00-12:00,14:00-18:00", date(10, 6, 15)), .open)
    }

    func testPublicHolidaysAndOff() throws {
        let rules = "Mo-Sa 10:00-20:00; Su off; PH off"
        XCTAssertEqual(try verdict(rules, date(10, 6, 12)), .open)
        XCTAssertEqual(try verdict(rules, date(10, 6, 12), holiday: ["2026-10-06"]), .closed("Closed on public holidays"))
        XCTAssertEqual(try verdict(rules, date(10, 11, 12)), .closed("Closed on Sundays"))
    }

    func testAlwaysOpen() throws {
        XCTAssertEqual(try verdict("24/7", date(10, 6, 3)), .open)
        XCTAssertEqual(try verdict("24/7", date(10, 10, 23, 30), minutes: 120), .open)
    }

    func testOvernightHoursSpillIntoTheNextMorning() throws {
        XCTAssertEqual(try verdict("Mo-Fr 22:00-02:00", date(10, 6, 1), minutes: 30), .open, "Monday night runs into Tuesday")
        XCTAssertEqual(try verdict("Mo-Fr 22:00-02:00", date(10, 10, 1), minutes: 30), .open, "Friday night runs into Saturday")
        XCTAssertEqual(try verdict("Mo-Fr 22:00-02:00", date(10, 10, 23), minutes: 30), .closed("Closed on Saturdays"))
    }

    func testCommaSeparatedRulesAndComments() throws {
        let rules = "Mo-Fr 09:00-12:00, Sa 10:00-14:00 \"by appointment on Sundays\""
        XCTAssertEqual(try verdict(rules, date(10, 10, 11)), .open)
        XCTAssertEqual(try verdict(rules, date(10, 10, 15)), .closed("Closed after 14:00"))
        XCTAssertEqual(try verdict(rules, date(10, 6, 10)), .open)
    }

    func testRulesTheParserCannotCheckAreRefused() {
        for text in ["sunrise-sunset", "Mo-Fr 09:00-17:00 || \"on appointment\"", "week 1-53/2 Mo 10:00-12:00",
                     "Dec 25 off", "Mo-Fr 10:00+", "Mo[1] 10:00-12:00", "Mo-Fr dusk-dawn", "", "Mo-Fr"] {
            XCTAssertNil(OpeningHours.parse(text), text)
        }
    }

    func testTextAndWeek() throws {
        let hours = try XCTUnwrap(OpeningHours.parse("Mo-Fr 09:00-12:00,14:00-18:00; Sa 10:00-14:00"))
        XCTAssertEqual(hours.text(on: date(10, 6), isHoliday: { _ in false }, calendar: calendar), "09:00–12:00, 14:00–18:00")
        XCTAssertEqual(hours.text(on: date(10, 11), isHoliday: { _ in false }, calendar: calendar), "Closed")

        let week = hours.week(around: date(10, 8), isHoliday: { _ in false }, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.day, "Monday")
        XCTAssertEqual(week.last?.text, "Closed")
    }

    func testWarningTexts() {
        XCTAssertNil(OpeningHours.warning(for: .open))
        XCTAssertNil(OpeningHours.warning(for: .unknown))
        XCTAssertEqual(OpeningHours.warning(for: .opensLater(600)), "Opens at 10:00, after your planned time")
        XCTAssertEqual(OpeningHours.warning(for: .closesEarly(1050)), "Closes at 17:30, before your visit ends")
        XCTAssertEqual(OpeningHours.warning(for: .closed("Closed on Mondays")), "Closed on Mondays")
    }

    // MARK: Finding hours on OpenStreetMap

    func testPicksTheElementThatIsThisPlace() {
        let here = CLLocationCoordinate2D(latitude: 38.6916, longitude: -9.2160)
        let elements: [[String: Any]] = [
            ["tags": ["name": "Souvenir shop", "opening_hours": "Mo-Su 09:00-20:00"], "lat": 38.69161, "lon": -9.21601],
            ["tags": ["name": "Torre de Belém", "opening_hours": "Tu-Su 10:00-17:30"],
             "center": ["lat": 38.6918, "lon": -9.2159]],
        ]
        XCTAssertEqual(OpeningHoursService.pick(from: elements, name: "Belém Tower", coordinate: here), "Mo-Su 09:00-20:00",
                       "no name matches, so the nearest within 25 m wins")
        XCTAssertEqual(OpeningHoursService.pick(from: elements, name: "Torre de Belém", coordinate: here), "Tu-Su 10:00-17:30")
        XCTAssertNil(OpeningHoursService.pick(from: [], name: "x", coordinate: here))
    }

    // MARK: Public holidays

    func testHolidaysKeepPublicOnesAndMarkRegionalOnes() {
        let rows: [[String: Any]] = [
            ["date": "2026-04-25", "name": "Freedom Day", "localName": "Dia da Liberdade", "global": true, "types": ["Public"]],
            ["date": "2026-02-17", "name": "Carnival", "localName": "Carnaval", "global": true, "types": ["Optional"]],
            ["date": "2026-06-13", "name": "St Anthony", "localName": "Santo António", "global": false, "types": ["Public"]],
        ]
        let holidays = PublicHolidays.parse(rows)
        XCTAssertEqual(holidays.map(\.date), ["2026-04-25", "2026-06-13"])
        XCTAssertEqual(holidays.map(\.isRegional), [false, true])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 4, day: 25, hour: 12))!
        XCTAssertEqual(PublicHolidays.holiday(on: day, in: holidays, calendar: calendar)?.name, "Freedom Day")
    }
}

final class RainPlanTests: XCTestCase {
    func testPlaceSettings() {
        XCTAssertEqual(PlaceSetting.classify(name: "Museu Nacional de Arte Antiga", kind: nil, category: .sight), .indoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Parque Eduardo VII", kind: nil, category: .sight), .outdoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Miradouro da Graça", kind: nil, category: .sight), .outdoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Museum Park", kind: nil, category: .sight), .mixed)
        XCTAssertEqual(PlaceSetting.classify(name: "Castelo de São Jorge", kind: nil, category: .sight), .mixed)
        XCTAssertEqual(PlaceSetting.classify(name: "Some Place", kind: .nature, category: nil), .outdoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Some Place", kind: .culture, category: nil), .indoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Park Café", kind: nil, category: .cafe), .indoor)
        XCTAssertEqual(PlaceSetting.classify(name: "Spanish Steps", kind: nil, category: .sight), .mixed, "not a spa")
        XCTAssertEqual(PlaceSetting.classify(name: "Jardim Botânico", kind: nil, category: .sight), .outdoor)
    }

    private func place(_ id: String, _ name: String, east: Double, score: Double, kind: DiscoverKind = .culture) -> SuggestedPlace {
        var place = SuggestedPlace(id: id, name: name,
                                   coordinate: CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14 + east * 0.01),
                                   kind: kind, distance: 0)
        place.score = score
        return place
    }

    func testIndoorCandidatesDropOutdoorOnesAndPlacesAlreadyInTheTrip() {
        let places = [
            place("1", "City Museum", east: 0, score: 0.9),
            place("2", "Central Park", east: 0, score: 0.9, kind: .nature),
            place("3", "Art Gallery", east: 0, score: 0.5),
            place("4", "Art Gallery", east: 0.1, score: 0.4),
        ]
        let result = RainPlanner.indoorCandidates(places, excludingNames: ["City Museum"])
        XCTAssertEqual(result.map(\.id), ["3"], "the museum is already planned, the park is outdoors, the gallery counts once")
    }

    func testEachOutdoorStopGetsItsOwnClosePlace() {
        let origin = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)
        let outdoor = [
            RainPlanner.OutdoorStop(id: "a", name: "Park A", coordinate: origin),
            RainPlanner.OutdoorStop(id: "b", name: "Park B", coordinate: origin),
        ]
        let candidates = [
            place("m1", "Museum One", east: 0.1, score: 0.9),
            place("m2", "Museum Two", east: 0.2, score: 0.6),
            place("far", "Far Museum", east: 50, score: 1.0),
        ]
        let proposals = RainPlanner.proposals(for: outdoor, candidates: candidates)

        XCTAssertEqual(proposals.map(\.outdoorID), ["a", "b"])
        XCTAssertEqual(proposals.map(\.place.id), ["m1", "m2"], "nothing is used twice and the far one is out of range")
    }

    func testNoCandidatesInRangeMeansNoProposals() {
        let origin = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)
        let proposals = RainPlanner.proposals(for: [RainPlanner.OutdoorStop(id: "a", name: "Park", coordinate: origin)],
                                              candidates: [place("far", "Far Museum", east: 50, score: 1)])
        XCTAssertTrue(proposals.isEmpty)
    }
}

final class PracticalInfoTests: XCTestCase {
    func testCountryFactsFromWikidata() throws {
        func binding(_ value: String) -> [String: Any] { ["type": "literal", "value": value] }
        let json: [String: Any] = ["results": ["bindings": [
            ["cLabel": binding("Portugal"), "emergencyLabel": binding("112"), "currencyLabel": binding("euro"),
             "sideLabel": binding("right"), "calling": binding("+351"), "voltage": binding("230")],
            ["cLabel": binding("Portugal"), "emergencyLabel": binding("112"), "currencyLabel": binding("Q4916")],
        ]]]
        let facts = try XCTUnwrap(CountryFactsService.parse(json))
        XCTAssertEqual(facts.name, "Portugal")
        XCTAssertEqual(facts.emergency, ["112"])
        XCTAssertEqual(facts.currency, ["euro"], "unlabelled entities are dropped")
        XCTAssertEqual(facts.callingCode, "+351")
        XCTAssertEqual(facts.voltage, "230")
        XCTAssertEqual(facts.drivingSide, "right")
        XCTAssertNil(CountryFactsService.parse([:]))
    }

    func testPicksTheWikivoyageSectionByName() {
        let sections: [[String: Any]] = [
            ["index": "1", "line": "Understand", "level": "2"],
            ["index": "7", "line": "Stay safe", "level": "2"],
            ["index": 9, "line": "Cope", "level": "2"],
        ]
        XCTAssertEqual(WikivoyageService.pickIndex(sections, named: ["Stay safe"]), "7")
        XCTAssertEqual(WikivoyageService.pickIndex(sections, named: ["Cope"]), "9")
        XCTAssertNil(WikivoyageService.pickIndex(sections, named: ["Connect"]))
    }

    func testInfoSurvivesStorageAndListsEmergencyNumbers() throws {
        let info = PracticalInfo(facts: CountryFacts(name: "Portugal", callingCode: "+351", voltage: "230",
                                                    drivingSide: "right", emergency: ["112", "police"], currency: ["euro"]),
                                 notes: PracticalNotes(safety: ["Watch for pickpockets on trams."]),
                                 guideText: "text", guideTitle: "Portugal", fetchedAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        let decoded = try XCTUnwrap(PracticalInfo.decode(json))
        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.emergencyNumbers, ["112"], "only entries with digits are numbers")
        XCTAssertNil(PracticalInfo.decode(""))
        XCTAssertFalse(decoded.notes?.isEmpty ?? true)
        XCTAssertTrue(PracticalNotes().isEmpty)
    }
}

final class PDFPaginatorTests: XCTestCase {
    func testASmallDayIsOnePage() {
        XCTAssertEqual(PDFPaginator.pages(count: 4, firstCapacity: 4, nextCapacity: 8), [0..<4])
    }

    func testLongDaysContinue() {
        XCTAssertEqual(PDFPaginator.pages(count: 15, firstCapacity: 4, nextCapacity: 8), [0..<4, 4..<12, 12..<15])
    }

    func testEmptyDayStillGetsAPage() {
        XCTAssertEqual(PDFPaginator.pages(count: 0, firstCapacity: 4, nextCapacity: 8), [0..<0])
    }
}
