import XCTest
import CoreLocation
import MapKit
@testable import TripPlanner

final class MustSeeParserTests: XCTestCase {
    func testPlainNameIsUnchanged() {
        let result = MustSeeParser.parse("Belém Tower")
        XCTAssertEqual(result, .init(query: "Belém Tower", minute: nil, day: nil))
    }

    func testClockTime() {
        let result = MustSeeParser.parse("Louvre at 10:30")
        XCTAssertEqual(result.query, "Louvre")
        XCTAssertEqual(result.minute, 10 * 60 + 30)
    }

    func testTwelveHourClock() {
        XCTAssertEqual(MustSeeParser.parse("Tower Bridge 6pm").minute, 18 * 60)
        XCTAssertEqual(MustSeeParser.parse("Tower Bridge at 6:15 pm").minute, 18 * 60 + 15)
        XCTAssertEqual(MustSeeParser.parse("Breakfast spot 12 am").minute, 0)
    }

    func testPartOfDayAndDay() {
        let result = MustSeeParser.parse("Belém Tower at sunset on day 2")
        XCTAssertEqual(result.query, "Belém Tower")
        XCTAssertEqual(result.minute, 19 * 60)
        XCTAssertEqual(result.day, 2)
    }

    func testSentence() {
        let result = MustSeeParser.parse("I want to see the Colosseum in the evening")
        XCTAssertEqual(result.query, "Colosseum")
        XCTAssertEqual(result.minute, 18 * 60 + 30)
    }

    func testGerman() {
        let result = MustSeeParser.parse("Brandenburger Tor um 18 Uhr")
        XCTAssertEqual(result.query, "Brandenburger Tor")
        XCTAssertEqual(result.minute, 18 * 60)
    }

    func testWeekdayWordIsNotADay() {
        XCTAssertNil(MustSeeParser.parse("Monday Market").day)
    }

    func testNumbersInNamesSurvive() {
        let result = MustSeeParser.parse("Pier 39")
        XCTAssertEqual(result.query, "Pier 39")
        XCTAssertNil(result.minute)
    }

    func testBareAtHourNeedsADaytimeHour() {
        XCTAssertEqual(MustSeeParser.parse("Museum at 14").minute, 14 * 60)
        XCTAssertNil(MustSeeParser.parse("Platz at 3").minute)
    }
}

final class MustSeePlanningTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)

    private func pool() -> [PlanCandidate] {
        var list: [PlanCandidate] = []
        for kind in [DiscoverKind.sights, .culture, .food, .cafe] {
            for i in 0..<15 {
                list.append(PlanCandidate(id: "\(kind.rawValue)-\(i)", name: "\(kind.title) \(i)",
                                          coordinate: CLLocationCoordinate2D(latitude: center.latitude + Double(i % 4) * 0.004,
                                                                             longitude: center.longitude + Double(i / 4) * 0.004),
                                          kind: kind, score: 1 - Double(i) / 20))
            }
        }
        return list
    }

    private func plan(_ extra: PlanCandidate) -> [PlannedDay] {
        var prefs = TripPreferences()
        prefs.days = 3
        prefs.group = .couple
        prefs.pace = .balanced
        prefs.interests = [.sights, .food]
        var rng = SplitMix64(seed: 7)
        return AutoPlanner.generate(candidates: pool() + [extra], prefs: prefs, center: center, variation: 0, using: &rng)
    }

    func testPreferredDayIsHonoured() {
        var place = PlanCandidate(id: "must-x", name: "Far Castle", coordinate: center, kind: .sights, score: 1)
        place.isMustSee = true
        place.preferredDay = 3
        let days = plan(place)
        XCTAssertTrue(days[2].stops.contains { $0.candidate.id == "must-x" })
        XCTAssertFalse(days[0].stops.contains { $0.candidate.id == "must-x" })
    }

    func testPreferredTimeIsNotBeforeTheWantedTime() {
        var place = PlanCandidate(id: "must-x", name: "Sunset Point", coordinate: center, kind: .sights, score: 1)
        place.isMustSee = true
        place.preferredDay = 1
        place.preferredMinute = 19 * 60
        let stop = plan(place)[0].stops.first { $0.candidate.id == "must-x" }
        XCTAssertNotNil(stop)
        XCTAssertGreaterThanOrEqual(stop?.startMinute ?? 0, 19 * 60)
    }

    func testTimedPlaceIsOrderedBetweenTheRightStops() {
        var place = PlanCandidate(id: "must-x", name: "Lunchtime Landmark", coordinate: center, kind: .sights, score: 1)
        place.isMustSee = true
        place.preferredDay = 1
        place.preferredMinute = 15 * 60
        let stops = plan(place)[0].stops
        let times = stops.map(\.startMinute)
        XCTAssertEqual(times, times.sorted(), "stops stay in time order")
        XCTAssertTrue(stops.contains { $0.candidate.id == "must-x" })
    }

    func testMustSeeKeepsItsWishesInTheCandidate() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: center))
        item.name = "Tower"
        let candidate = MustSee(item: item, preferredMinute: 600, preferredDay: 2).candidate()
        XCTAssertTrue(candidate.isMustSee)
        XCTAssertEqual(candidate.preferredMinute, 600)
        XCTAssertEqual(candidate.preferredDay, 2)
        XCTAssertEqual(MustSee(item: item, preferredMinute: 600, preferredDay: 2).whenText, "Around 10:00 · Day 2")
    }
}

final class TravelLegTests: XCTestCase {
    private let a = CLLocationCoordinate2D(latitude: 38.7100, longitude: -9.1400)
    private let b = CLLocationCoordinate2D(latitude: 38.7300, longitude: -9.1400)   // about 2.2 km

    func testModeFollowsThePreferredTransport() {
        XCTAssertEqual(TravelLeg.mode(for: .walking), .walk)
        XCTAssertEqual(TravelLeg.mode(for: .transit), .transit)
        XCTAssertEqual(TravelLeg.mode(for: .car), .drive)
    }

    func testWalkingIsSlowerThanDriving() {
        let walk = TravelLeg.estimate(from: a, to: b, transport: .walking)
        let drive = TravelLeg.estimate(from: a, to: b, transport: .car)
        XCTAssertGreaterThan(walk.seconds, drive.seconds * 3)
        XCTAssertEqual(walk.meters, drive.meters, accuracy: 0.1)
    }

    func testLongWalkIsFlagged() {
        let far = CLLocationCoordinate2D(latitude: 38.7600, longitude: -9.1400)
        XCTAssertFalse(TravelLeg.estimate(from: a, to: b, transport: .walking).isLongWalk)
        XCTAssertTrue(TravelLeg.estimate(from: a, to: far, transport: .walking).isLongWalk)
        XCTAssertFalse(TravelLeg.estimate(from: a, to: far, transport: .car).isLongWalk)
    }

    func testPartitionSeparatesFarResults() {
        let near = MKMapItem(placemark: MKPlacemark(coordinate: b))
        let far = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)))
        let split = PlaceSearchService.partition([far, near], around: a, within: 150_000)
        XCTAssertEqual(split.near.count, 1)
        XCTAssertEqual(split.far.count, 1)
        XCTAssertEqual(PlaceSearchService.partition([far, near], around: nil, within: 1).near.count, 2)
    }
}

final class MustSeeListTests: XCTestCase {
    func testPastedParagraphIsRecognisedAsAList() {
        let text = "1. Place of culture observatory for a beautiful skyline view or Verso Tower maybe also at night 2. Świętokrzyski Bridge also at night for the view"
        XCTAssertTrue(MustSeeParser.looksLikeList(text))
        XCTAssertFalse(MustSeeParser.looksLikeList("Belém Tower at sunset"))
        XCTAssertTrue(MustSeeParser.looksLikeList("Louvre\nEiffel Tower"))
    }

    func testSplitFindsEachPlaceWithoutTheExplanations() {
        let text = "1. Place of culture observatory for a beautiful skyline view or Verso Tower maybe also at night 2. Świętokrzyski Bridge also at night for the view"
        let places = MustSeeParser.split(text)
        XCTAssertEqual(places.map(\.query), ["Place of culture observatory", "Verso Tower", "Świętokrzyski Bridge"])
        XCTAssertNil(places[0].minute)
        XCTAssertEqual(places[1].minute, 21 * 60)
        XCTAssertEqual(places[2].minute, 21 * 60)
    }

    func testNamesWithForAreKept() {
        XCTAssertEqual(MustSeeParser.split("Museum for Modern Art\nOld Town").map(\.query), ["Museum for Modern Art", "Old Town"])
    }

    func testDuplicatesAreDropped() {
        XCTAssertEqual(MustSeeParser.split("Louvre\nlouvre\nEiffel Tower").map(\.query), ["Louvre", "Eiffel Tower"])
    }
}

final class PickedPlaceTests: XCTestCase {
    func testSearchedPlaceCanBeAddedToADay() {
        let center = CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: center))
        item.name = "Time Out Market"
        let candidate = PlanCandidate(picked: item)
        XCTAssertEqual(candidate.name, "Time Out Market")
        XCTAssertFalse(candidate.isMustSee)

        var prefs = TripPreferences()
        prefs.interests = [.sights]
        let day = PlannedDay(stops: [], theme: "")
        let outcome = PlanEditor.apply([.add(candidate.id, after: nil)], to: day, pool: [candidate], usedElsewhere: [],
                                       prefs: prefs, window: DayWindow())
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.day.stops.map(\.candidate.id), [candidate.id])
    }
}

final class ArrangeTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122)

    private func place(_ id: String, dLat: Double, dLon: Double, kind: DiscoverKind = .sights) -> PlanCandidate {
        var candidate = PlanCandidate(id: id, name: "Place \(id)",
                                      coordinate: CLLocationCoordinate2D(latitude: center.latitude + dLat,
                                                                         longitude: center.longitude + dLon),
                                      kind: kind, score: 1)
        candidate.isMustSee = true
        return candidate
    }

    private func prefs(days: Int) -> TripPreferences {
        var value = TripPreferences()
        value.days = days
        value.group = .couple
        return value
    }

    func testOnlyTheGivenPlacesAreUsed() {
        let places = (0..<6).map { place("p\($0)", dLat: Double($0) * 0.004, dLon: 0) }
        let result = AutoPlanner.arrange(places: places, prefs: prefs(days: 2), center: center)
        let ids = Set(result.days.flatMap { $0.stops.map(\.candidate.id) })
        XCTAssertEqual(ids, Set(places.map(\.id)))
        XCTAssertTrue(result.leftOut.isEmpty)
    }

    func testPlacesAreSpreadOverTheDaysByArea() {
        // Two clusters about 9 km apart.
        let west = (0..<3).map { place("w\($0)", dLat: Double($0) * 0.002, dLon: -0.06) }
        let east = (0..<3).map { place("e\($0)", dLat: Double($0) * 0.002, dLon: 0.06) }
        let result = AutoPlanner.arrange(places: west + east, prefs: prefs(days: 2), center: center)
        let dayIDs = result.days.map { Set($0.stops.map(\.candidate.id)) }
        XCTAssertTrue(dayIDs.contains(Set(west.map(\.id))))
        XCTAssertTrue(dayIDs.contains(Set(east.map(\.id))))
    }

    func testWantedDayAndTimeAreKept() {
        var tower = place("tower", dLat: 0, dLon: 0)
        tower.preferredDay = 2
        tower.preferredMinute = 19 * 60
        let others = (0..<3).map { place("o\($0)", dLat: Double($0) * 0.003, dLon: 0.002) }
        let result = AutoPlanner.arrange(places: others + [tower], prefs: prefs(days: 2), center: center)
        let stop = result.days[1].stops.first { $0.candidate.id == "tower" }
        XCTAssertNotNil(stop)
        XCTAssertGreaterThanOrEqual(stop?.startMinute ?? 0, 19 * 60)
        let times = result.days[1].stops.map(\.startMinute)
        XCTAssertEqual(times, times.sorted())
    }

    func testTooManyPlacesAreReportedNotLost() {
        let places = (0..<30).map { place("p\($0)", dLat: Double($0) * 0.001, dLon: 0) }
        let result = AutoPlanner.arrange(places: places, prefs: prefs(days: 1), center: center)
        let planned = result.days.flatMap { $0.stops.map(\.candidate.id) }
        XCTAssertEqual(planned.count + result.leftOut.count, 30)
        XCTAssertFalse(result.leftOut.isEmpty)
    }

    func testRestaurantBecomesLunchNotAMorningStop() {
        let sights = (0..<2).map { place("s\($0)", dLat: Double($0) * 0.003, dLon: 0) }
        let cafe = place("food", dLat: 0.002, dLon: 0, kind: .food)
        let result = AutoPlanner.arrange(places: sights + [cafe], prefs: prefs(days: 1), center: center)
        let meal = result.days[0].stops.first { $0.candidate.id == "food" }
        XCTAssertEqual(meal?.slot, .lunch)
        XCTAssertGreaterThanOrEqual(meal?.startMinute ?? 0, 12 * 60 + 15)
    }

    func testEmptyListGivesFreeDays() {
        let result = AutoPlanner.arrange(places: [], prefs: prefs(days: 3), center: center)
        XCTAssertEqual(result.days.count, 3)
        XCTAssertTrue(result.days.allSatisfy { $0.stops.isEmpty })
    }

    func testFixedDurationIsUsed() {
        var stop = place("long", dLat: 0, dLon: 0)
        stop.fixedDuration = 200
        let result = AutoPlanner.arrange(places: [stop], prefs: prefs(days: 1), center: center)
        XCTAssertEqual(result.days[0].stops.first?.durationMinutes, 200)
    }

    func testFixedRestaurantReplacesThatDaysLunch() {
        var prefs = prefs(days: 1)
        prefs.interests = [.sights, .food]
        prefs.includeLunch = true
        prefs.includeDinner = false
        var chosen = place("mine", dLat: 0, dLon: 0, kind: .food)
        chosen.preferredDay = 1
        var pool: [PlanCandidate] = [chosen]
        for i in 0..<10 {
            pool.append(PlanCandidate(id: "f\(i)", name: "Food \(i)",
                                      coordinate: CLLocationCoordinate2D(latitude: center.latitude + Double(i) * 0.001,
                                                                         longitude: center.longitude),
                                      kind: .food, score: 0.9))
            pool.append(PlanCandidate(id: "s\(i)", name: "Sight \(i)",
                                      coordinate: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + Double(i) * 0.001),
                                      kind: .sights, score: 0.8))
        }
        var rng = SplitMix64(seed: 3)
        let day = AutoPlanner.generate(candidates: pool, prefs: prefs, center: center, variation: 0, using: &rng)[0]
        XCTAssertEqual(day.stops.filter { $0.slot == .lunch }.map(\.candidate.id), ["mine"])
        XCTAssertEqual(day.stops.filter { $0.candidate.kind == .food }.count, 1, "no second restaurant is added")
    }
}
