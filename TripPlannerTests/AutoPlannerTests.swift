import XCTest
import CoreLocation
@testable import TripPlanner

final class AutoPlannerTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)

    /// 20 places per kind on a small grid around the centre, best-rated first.
    private func pool(perKind: Int = 20) -> [PlanCandidate] {
        let kinds: [DiscoverKind] = [.sights, .culture, .nature, .food, .cafe, .nightlife, .fun, .shopping]
        var list: [PlanCandidate] = []
        for kind in kinds {
            for i in 0..<perKind {
                let column = Double(i % 5 - 2)
                let row = Double(i / 5 - 2)
                list.append(PlanCandidate(
                    id: "\(kind.rawValue)-\(i)",
                    name: "\(kind.title) place \(i)",
                    coordinate: CLLocationCoordinate2D(latitude: center.latitude + row * 0.005,
                                                       longitude: center.longitude + column * 0.006),
                    kind: kind,
                    score: 1 - Double(i) / Double(perKind + 5)))
            }
        }
        return list
    }

    private func prefs(_ change: (inout TripPreferences) -> Void = { _ in }) -> TripPreferences {
        var value = TripPreferences()
        value.days = 3
        value.group = .couple
        value.pace = .balanced
        value.interests = [.sights, .food]
        change(&value)
        return value
    }

    private func plan(_ prefs: TripPreferences, candidates: [PlanCandidate]? = nil) -> [PlannedDay] {
        var rng = SplitMix64(seed: 42)
        return AutoPlanner.generate(candidates: candidates ?? pool(), prefs: prefs, center: center, variation: 0, using: &rng)
    }

    func testDayAndStopCounts() {
        let days = plan(prefs())
        XCTAssertEqual(days.count, 3)
        for day in days {
            XCTAssertEqual(day.stops.filter { $0.slot == .activity }.count, 3)
            XCTAssertEqual(day.stops.count, 5, "3 sights + lunch + dinner")
        }
    }

    func testPaceChangesStopCount() {
        let relaxed = plan(prefs { $0.pace = .relaxed })
        let packed = plan(prefs { $0.pace = .packed })
        XCTAssertLessThan(relaxed[0].stops.count, packed[0].stops.count)
    }

    func testMealsWaitForTheirHour() {
        for day in plan(prefs()) {
            let lunch = day.stops.filter { $0.slot == .lunch }
            let dinner = day.stops.filter { $0.slot == .dinner }
            XCTAssertEqual(lunch.count, 1)
            XCTAssertEqual(dinner.count, 1)
            XCTAssertGreaterThanOrEqual(lunch[0].startMinute, 12 * 60 + 15)
            XCTAssertGreaterThanOrEqual(dinner[0].startMinute, 18 * 60 + 45)
        }
    }

    func testNoPlaceIsUsedTwice() {
        let ids = plan(prefs { $0.days = 4 }).flatMap { $0.stops.map(\.candidate.id) }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testTimesIncreaseAndStayInsideTheDay() {
        let settings = prefs()
        for day in plan(settings) {
            let times = day.stops.map(\.startMinute)
            XCTAssertEqual(times, times.sorted())
            XCTAssertEqual(Set(times).count, times.count)
            XCTAssertGreaterThanOrEqual(times.first ?? 0, settings.dayStart.minutes)
            XCTAssertLessThan(times.last ?? 0, settings.endLimitMinutes)
        }
    }

    func testFamilyTripsHaveNoNightlifeAndEndEarly() {
        let settings = prefs {
            $0.group = .family
            $0.interests = [.sights, .food, .nightlife]
        }
        for day in plan(settings) {
            XCTAssertFalse(day.stops.contains { $0.candidate.kind == .nightlife })
            XCTAssertLessThan(day.stops.map(\.startMinute).max() ?? 0, 19 * 60 + 30)
        }
    }

    func testFriendsGetNightlife() {
        let settings = prefs {
            $0.group = .friends
            $0.interests = [.sights, .food, .nightlife]
            $0.nightEndHour = 24
        }
        for day in plan(settings) {
            let night = day.stops.filter { $0.slot == .nightlife }
            XCTAssertEqual(night.count, 1)
            XCTAssertGreaterThanOrEqual(night[0].startMinute, 20 * 60 + 30)
        }
    }

    func testMustSeeIsIncluded() {
        var special = PlanCandidate(id: "must-tower", name: "Special Tower",
                                    coordinate: center, kind: .sights, score: 1)
        special.isMustSee = true
        let days = plan(prefs(), candidates: pool() + [special])
        XCTAssertTrue(days.contains { $0.stops.contains { $0.candidate.id == "must-tower" } })
    }

    func testSmallPoolDoesNotCrash() {
        let tiny = Array(pool().filter { $0.kind == .sights }.prefix(3))
        let days = plan(prefs(), candidates: tiny)
        XCTAssertEqual(days.count, 3)
        XCTAssertLessThanOrEqual(days.reduce(0) { $0 + $1.stops.count }, 3)
    }

    func testEmptyPoolGivesEmptyDays() {
        let days = plan(prefs(), candidates: [])
        XCTAssertEqual(days.count, 3)
        XCTAssertTrue(days.allSatisfy { $0.stops.isEmpty })
    }

    func testHiddenGemsFlattenPopularity() {
        let popular = PlanCandidate(id: "a", name: "A", coordinate: center, kind: .sights, score: 0.9)
        let obscure = PlanCandidate(id: "b", name: "B", coordinate: center, kind: .sights, score: 0.1)
        let normal = prefs()
        let gems = prefs { $0.interests.insert(.hiddenGems) }
        let normalGap = AutoPlanner.adjusted(popular, normal) - AutoPlanner.adjusted(obscure, normal)
        let gemGap = AutoPlanner.adjusted(popular, gems) - AutoPlanner.adjusted(obscure, gems)
        XCTAssertLessThan(gemGap, normalGap)
    }

    func testDayCentresSeparateTwoAreas() {
        let north = (0..<5).map { CLLocationCoordinate2D(latitude: 38.80 + Double($0) * 0.001, longitude: -9.14) }
        let south = (0..<5).map { CLLocationCoordinate2D(latitude: 38.60 + Double($0) * 0.001, longitude: -9.14) }
        let points = north + south
        let centres = AutoPlanner.dayCentres(points: points, weights: Array(repeating: 1, count: points.count), count: 2)

        XCTAssertEqual(centres.count, 2)
        XCTAssertEqual(centres.filter { $0.latitude > 38.7 }.count, 1)
        XCTAssertEqual(centres.filter { $0.latitude < 38.7 }.count, 1)
    }

    func testPreferencesSurviveEncoding() throws {
        var settings = prefs {
            $0.interests = [.nightlife, .museums, .hiddenGems]
            $0.cuisines = ["italian", "asian"]
            $0.vegetarian = true
        }
        settings.transport = .car
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TripPreferences.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: Flights and hotel

    private func planWithWindows(_ settings: TripPreferences, _ windows: [DayWindow]) -> [PlannedDay] {
        var rng = SplitMix64(seed: 7)
        return AutoPlanner.generate(candidates: pool(), prefs: settings, center: center, variation: 0,
                                    windows: windows, using: &rng)
    }

    func testArrivalDayStartsAfterTheWindowAndSkipsAnAfternoonLunch() {
        var arrival = DayWindow()
        arrival.startMinute = 16 * 60 + 30
        let days = planWithWindows(prefs(), [arrival, DayWindow(), DayWindow()])

        XCTAssertTrue(days[0].stops.allSatisfy { $0.startMinute >= 16 * 60 + 30 })
        XCTAssertFalse(days[0].stops.contains { $0.slot == .lunch }, "no lunch at 5 pm")
        XCTAssertTrue(days[0].stops.contains { $0.slot == .dinner })
        XCTAssertEqual(days[1].stops.first.map { $0.startMinute < 12 * 60 }, true)
    }

    func testDepartureDayEndsBeforeLeavingForTheAirport() {
        var departure = DayWindow()
        departure.endMinute = 15 * 60 + 20
        let days = planWithWindows(prefs(), [DayWindow(), DayWindow(), departure])

        XCTAssertTrue(days[2].stops.allSatisfy { $0.startMinute < 15 * 60 + 20 })
        XCTAssertFalse(days[2].stops.contains { $0.slot == .dinner })
    }

    func testHotelAnchorAddsTravelBeforeTheFirstStop() {
        var window = DayWindow()
        window.anchor = CLLocationCoordinate2D(latitude: center.latitude + 0.03, longitude: center.longitude)
        let settings = prefs()
        let days = planWithWindows(settings, [window, DayWindow(), DayWindow()])

        // 3 km from the hotel: the first stop can't start at the day start itself.
        XCTAssertGreaterThan(days[0].stops[0].startMinute, settings.dayStart.minutes)
    }
}
