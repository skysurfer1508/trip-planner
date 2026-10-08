import XCTest
import CoreLocation
@testable import TripPlanner

final class TransitSanityTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122)

    /// A point about `meters` north of the origin.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + meters / 111_000, longitude: origin.longitude)
    }

    private func leg(_ mode: TransitMode, minutes: Int, meters: Double, stops: Int = 3, line: String? = nil) -> TransitLeg {
        TransitLeg(mode: mode, fromName: "A", toName: "B", from: TransitPoint(lat: 0, lon: 0), to: TransitPoint(lat: 0, lon: 0),
                   routeShortName: line, distance: meters, duration: minutes * 60, stopCount: stops, path: [])
    }

    private func route(_ legs: [TransitLeg], transfers: Int = 0) -> TransitItinerary {
        TransitItinerary(duration: legs.reduce(0) { $0 + $1.duration }, transfers: transfers, start: nil, end: nil, legs: legs)
    }

    func testWalkingRouteMatchesTheDistance() {
        let walk = TransitSanity.walking(from: origin, to: north(1_300))
        XCTAssertTrue(walk.transitLegs.isEmpty)
        XCTAssertEqual(Double(walk.duration), 1_300 * 1.25 / 1.3, accuracy: 5)
    }

    func testShortHopsAreWalks() {
        // 500 m away: a 9-minute tram trip is not better than a 8-minute walk.
        let tram = route([leg(.walk, minutes: 3, meters: 200), leg(.tram, minutes: 4, meters: 600, line: "17"),
                          leg(.walk, minutes: 2, meters: 100)])
        let result = TransitSanity.refine([tram], from: origin, to: north(500))
        XCTAssertTrue(result.first?.transitLegs.isEmpty ?? false, "walking comes first")
    }

    func testRealImprovementOverWalkingStays() {
        // 3.5 km: far too long to walk.
        let metro = route([leg(.walk, minutes: 4, meters: 300), leg(.subway, minutes: 8, meters: 3_400, stops: 4, line: "M1"),
                           leg(.walk, minutes: 3, meters: 250)])
        let result = TransitSanity.refine([metro], from: origin, to: north(3_500))
        XCTAssertEqual(result.first?.transitLegs.first?.routeShortName, "M1")
    }

    func testAbsurdRoutesAreDropped() {
        let far = north(4_000)
        let good = route([leg(.walk, minutes: 4, meters: 300), leg(.bus, minutes: 12, meters: 4_200, line: "180"),
                          leg(.walk, minutes: 3, meters: 200)])
        let manyChanges = route([leg(.bus, minutes: 30, meters: 5_000, line: "1")], transfers: 5)
        let longWalk = route([leg(.walk, minutes: 24, meters: 1_900), leg(.tram, minutes: 6, meters: 2_300, line: "9")])
        let oneStop = route([leg(.walk, minutes: 5, meters: 380), leg(.tram, minutes: 2, meters: 300, stops: 0, line: "2"),
                             leg(.walk, minutes: 5, meters: 380)])
        let detour = route([leg(.bus, minutes: 40, meters: 21_000, line: "N")])
        let result = TransitSanity.refine([manyChanges, longWalk, oneStop, detour, good], from: origin, to: far)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.transitLegs.first?.routeShortName, "180")
    }

    func testFewerChangesBeatASlightlyFasterRoute() {
        let direct = route([leg(.walk, minutes: 4, meters: 300), leg(.bus, minutes: 22, meters: 5_000, line: "A"),
                            leg(.walk, minutes: 3, meters: 200)])
        let changing = route([leg(.walk, minutes: 4, meters: 300), leg(.tram, minutes: 8, meters: 2_000, line: "B"),
                              leg(.subway, minutes: 12, meters: 3_000, line: "C"), leg(.walk, minutes: 3, meters: 200)],
                             transfers: 2)
        let result = TransitSanity.refine([changing, direct], from: origin, to: north(5_000))
        XCTAssertEqual(result.first?.transitLegs.first?.routeShortName, "A")
    }

    func testALateDepartureLosesToAnEarlierOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func timed(_ minutesFromNow: Int, line: String) -> TransitItinerary {
            var itinerary = route([leg(.walk, minutes: 3, meters: 250), leg(.bus, minutes: 15, meters: 4_500, line: line),
                                   leg(.walk, minutes: 2, meters: 150)])
            itinerary.start = now.addingTimeInterval(TimeInterval(minutesFromNow * 60))
            return itinerary
        }
        let result = TransitSanity.refine([timed(50, line: "late"), timed(4, line: "soon")], from: origin, to: north(4_500), requestedAt: now)
        XCTAssertEqual(result.first?.transitLegs.first?.routeShortName, "soon")
    }

    func testUnnamedLinesAreToldApartByTheirTrip() {
        func unnamed(_ trip: String) -> TransitItinerary {
            var vehicle = leg(.rail, minutes: 20, meters: 9_000, line: nil)
            vehicle.tripId = trip
            return route([leg(.walk, minutes: 4, meters: 300), vehicle])
        }
        XCTAssertEqual(TransitSanity.refine([unnamed("a"), unnamed("b")], from: origin, to: north(9_000)).count, 2)
    }

    func testSameLinesAreOfferedOnce() {
        let a = route([leg(.walk, minutes: 4, meters: 300), leg(.bus, minutes: 12, meters: 4_000, line: "180")])
        let b = route([leg(.walk, minutes: 4, meters: 300), leg(.bus, minutes: 13, meters: 4_000, line: "180")])
        XCTAssertEqual(TransitSanity.refine([a, b], from: origin, to: north(4_000)).count, 1)
    }

    func testCoverageIsNotLostWhenEverythingLooksOdd() {
        let odd = route([leg(.walk, minutes: 22, meters: 1_700), leg(.rail, minutes: 25, meters: 28_000, line: "S1")])
        let result = TransitSanity.refine([odd], from: origin, to: north(30_000))
        XCTAssertEqual(result.count, 1, "far apart: the only answer is kept")
        XCTAssertEqual(result.first?.transitLegs.first?.routeShortName, "S1")

        // About a 25-minute walk, and the only transit answer has a rejected long walk: walk instead.
        let near = TransitSanity.refine([route([leg(.walk, minutes: 22, meters: 1_700), leg(.tram, minutes: 10, meters: 800, line: "7")])],
                                        from: origin, to: north(1_900))
        XCTAssertTrue(near.first?.transitLegs.isEmpty ?? false)
    }
}

final class TransitEntranceTests: XCTestCase {
    func testEntranceNamesInSeveralLanguages() {
        XCTAssertTrue(TransitEntrances.looksLikeEntrance("Centrum Metro Entrance"))
        XCTAssertTrue(TransitEntrances.looksLikeEntrance("Wejście do metra Ratusz Arsenał"))
        XCTAssertTrue(TransitEntrances.looksLikeEntrance("U-Bahn Eingang Alexanderplatz"))
        XCTAssertTrue(TransitEntrances.looksLikeEntrance("Sortie 3 Châtelet"))
        XCTAssertFalse(TransitEntrances.looksLikeEntrance("Centrum Metro Station"))
    }

    func testNearestPrefersRealEntrancesToTheStationMarker() {
        let station = StationEntrance(name: "Centrum", latitude: 52.2300, longitude: 21.0100, source: "Apple Maps", isEntrance: false)
        let north = StationEntrance(name: "Exit 1", latitude: 52.2310, longitude: 21.0100, source: "OpenStreetMap", isEntrance: true)
        let south = StationEntrance(name: "Exit 2", latitude: 52.2290, longitude: 21.0100, source: "OpenStreetMap", isEntrance: true)
        let from = CLLocationCoordinate2D(latitude: 52.2280, longitude: 21.0100)
        XCTAssertEqual(TransitEntrances.nearest([station, north, south], to: from)?.name, "Exit 2")
        XCTAssertEqual(TransitEntrances.nearest([station], to: from)?.name, "Centrum", "the station itself if nothing else")
        XCTAssertNil(TransitEntrances.nearest([], to: from))
    }

    func testOpenStreetMapAnswerIsParsed() {
        let json: [String: Any] = ["elements": [
            ["type": "node", "lat": 52.231, "lon": 21.011, "tags": ["railway": "subway_entrance", "name": "Wejście A"]],
            ["type": "node", "lat": 52.232, "lon": 21.012, "tags": ["railway": "subway_entrance", "ref": "3"]],
            ["type": "node", "lat": 52.233, "lon": 21.013, "tags": ["railway": "subway_entrance"]],
            ["type": "node", "tags": [:]],
        ]]
        let list = TransitEntrances.parseOverpass(json)
        XCTAssertEqual(list.map(\.name), ["Wejście A", "Exit 3", "Metro entrance"])
        XCTAssertTrue(list.allSatisfy { $0.isEntrance && $0.source == "OpenStreetMap" })
    }
}
