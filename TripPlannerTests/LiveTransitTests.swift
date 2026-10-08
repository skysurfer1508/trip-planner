import XCTest
import CoreLocation
@testable import TripPlanner

/// Parsing and maths for live public transport, mostly against answers captured from api.transitous.org.
final class LiveTransitTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func leg(_ mode: TransitMode, depart: TimeInterval, arrive: TimeInterval, live: Bool = false, delay: TimeInterval = 0,
                     cancelled: Bool = false, line: String? = "1", walk: Int = 0) -> TransitLeg {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var value = TransitLeg(mode: mode, fromName: "A", toName: "B", from: TransitPoint(lat: 0, lon: 0), to: TransitPoint(lat: 0, lon: 0),
                               departure: base.addingTimeInterval(depart + delay), arrival: base.addingTimeInterval(arrive + delay),
                               routeShortName: line, distance: 1000, duration: walk > 0 ? walk : Int(arrive - depart), stopCount: 3, path: [])
        value.realTime = live
        value.cancelled = cancelled
        value.scheduledDeparture = base.addingTimeInterval(depart)
        value.scheduledArrival = base.addingTimeInterval(arrive)
        return value
    }

    // MARK: Parsing a real answer

    func testRealPlanAnswerKeepsLiveFields() throws {
        let itineraries = TransitousService.parse(try fixture("transitous-plan-warsaw"))
        XCTAssertEqual(itineraries.count, 2)
        let tram = try XCTUnwrap(itineraries[0].transitLegs.first)
        XCTAssertEqual(tram.mode, .tram)
        XCTAssertEqual(tram.routeShortName, "24")
        XCTAssertTrue(tram.isLive)
        XCTAssertEqual(tram.departureDelayMinutes, 1, "scheduled 09:34, live 09:35")
        XCTAssertEqual(tram.arrivalDelayMinutes, 1)
        XCTAssertEqual(tram.status, .late(1))
        XCTAssertNotNil(tram.fromStopId)
        XCTAssertNotNil(tram.tripId)
        XCTAssertNotNil(itineraries[0].id)
        XCTAssertTrue(itineraries[0].hasLiveData)
        XCTAssertFalse(itineraries[0].hasCancelledLeg)

        let walk = try XCTUnwrap(itineraries[0].legs.first)
        XCTAssertTrue(walk.isWalking)
        XCTAssertEqual(walk.status, .scheduled)
    }

    func testRealBusIsThreeMinutesLate() throws {
        let itineraries = TransitousService.parse(try fixture("transitous-plan-warsaw"))
        let bus = try XCTUnwrap(itineraries[1].transitLegs.first)
        XCTAssertEqual(bus.mode, .bus)
        XCTAssertEqual(bus.departureDelayMinutes, 3)
        XCTAssertEqual(bus.status, .late(3))
        XCTAssertEqual(itineraries[1].transfers, 1)
        XCTAssertEqual(itineraries[1].changeSlackMinutes.count, 1)
    }

    func testRealAnswerSurvivesTheSanityCheck() throws {
        let itineraries = TransitousService.parse(try fixture("transitous-plan-warsaw"))
        let from = CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122)
        let to = CLLocationCoordinate2D(latitude: 52.2409, longitude: 21.0836)   // about 5 km
        let result = TransitSanity.refine(itineraries, from: from, to: to)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result[0].transitLegs.isEmpty, "5 km is not a walk")
    }

    func testOldSavedRoutesWithoutLiveFieldsStillDecode() throws {
        let json = """
        {"duration": 600, "transfers": 0, "legs": [{"mode": "bus", "fromName": "A", "toName": "B",
         "from": {"lat": 1, "lon": 2}, "to": {"lat": 3, "lon": 4}, "distance": 100, "duration": 300, "stopCount": 2, "path": []}]}
        """
        let decoded = try JSONDecoder().decode(TransitItinerary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.legs.count, 1)
        XCTAssertNil(decoded.id)
        XCTAssertFalse(decoded.hasLiveData)
        XCTAssertEqual(decoded.legs[0].status, .scheduled)
    }

    // MARK: Delay and status

    func testStatuses() {
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600).status, .scheduled)
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600, live: true).status, .onTime)
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600, live: true, delay: 180).status, .late(3))
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600, live: true, delay: -120).status, .early(2))
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600, live: true, cancelled: true).status, .cancelled)
        XCTAssertEqual(leg(.bus, depart: 0, arrive: 600, live: true, delay: 20).status, .onTime, "under half a minute is on time")
    }

    // MARK: Changes

    func testChangeSlackSubtractsTheWalk() {
        let itinerary = TransitItinerary(duration: 3000, transfers: 1, start: nil, end: nil, legs: [
            leg(.walk, depart: -300, arrive: 0, line: nil),
            leg(.bus, depart: 0, arrive: 600),
            leg(.walk, depart: 600, arrive: 780, line: nil, walk: 180),
            leg(.tram, depart: 960, arrive: 1500),
        ])
        // Off the bus at 10:00, three minutes walking, tram at 16:00: 3 minutes to spare.
        XCTAssertEqual(itinerary.changeSlackMinutes, [3])
    }

    func testALateFirstVehicleMakesTheChangeTight() {
        let onTime = TransitItinerary(duration: 3000, transfers: 1, start: nil, end: nil, legs: [
            leg(.bus, depart: 0, arrive: 600, live: true), leg(.tram, depart: 780, arrive: 1500, live: true),
        ])
        let late = TransitItinerary(duration: 3000, transfers: 1, start: nil, end: nil, legs: [
            leg(.bus, depart: 0, arrive: 600, live: true, delay: 240), leg(.tram, depart: 780, arrive: 1500, live: true),
        ])
        XCTAssertEqual(onTime.changeSlackMinutes, [3])
        XCTAssertEqual(late.changeSlackMinutes, [-1], "the bus arrives after the tram has gone")
    }

    // MARK: Leave by

    func testLeaveByIsDepartureLessWalkAndBuffer() {
        let itinerary = TransitItinerary(duration: 1500, transfers: 0, start: nil, end: nil, legs: [
            leg(.walk, depart: -300, arrive: 0, line: nil, walk: 300),
            leg(.tram, depart: 600, arrive: 1500, live: true, delay: 60),
        ])
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Tram leaves at +660 s (live); 300 s walk and 120 s buffer.
        XCTAssertEqual(TransitLive.leaveBy(itinerary), base.addingTimeInterval(660 - 300 - 120))
        XCTAssertNil(TransitLive.leaveBy(TransitSanity.walking(from: .init(latitude: 0, longitude: 0), to: .init(latitude: 0, longitude: 0.001))))
    }

    func testCountdownText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TransitLive.countdownText(until: now.addingTimeInterval(4 * 60 + 10), now: now), "in 4 min")
        XCTAssertEqual(TransitLive.countdownText(until: now.addingTimeInterval(20), now: now), "now")
        XCTAssertEqual(TransitLive.countdownText(until: now.addingTimeInterval(-130), now: now), "left 3 min ago")
    }

    // MARK: Service calls

    func testIdsAreEscapedForTheRefreshCall() throws {
        let url = try XCTUnwrap(TransitLive.refreshURL(itineraryId: "ab/cd+ef=gh"))
        XCTAssertTrue(url.absoluteString.contains("itineraryId=ab%2Fcd%2Bef%3Dgh"), url.absoluteString)
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://api.transitous.org/api/v6/refresh-itinerary"))
    }

    func testDepartureBoardURL() throws {
        let url = try XCTUnwrap(TransitLive.departuresURL(stopId: "pl-Warszawa_centrum09-0ea49", at: Date(timeIntervalSince1970: 1_800_000_000), count: 8))
        XCTAssertTrue(url.absoluteString.contains("stopId=pl-Warszawa_centrum09-0ea49"))
        XCTAssertTrue(url.absoluteString.contains("n=8"))
        XCTAssertTrue(url.absoluteString.contains("time=2027-01-15T08%3A00%3A00Z"), url.absoluteString)
    }

    func testRealDepartureBoardIsParsedAndSorted() throws {
        let board = TransitLive.parseDepartures(try fixture("transitous-stoptimes-warsaw"))
        XCTAssertEqual(board.count, 3)
        XCTAssertEqual(board.map(\.departure), board.map(\.departure).sorted())
        XCTAssertTrue(board.allSatisfy { $0.mode != .other && !($0.line ?? "").isEmpty && $0.headsign != nil })
        XCTAssertTrue(board.contains { $0.realTime }, "Warsaw shares live data")
    }

    func testBoardDelayAndCancelled() {
        let json: [String: Any] = ["stopTimes": [
            ["place": ["departure": "2027-01-15T08:07:00Z", "scheduledDeparture": "2027-01-15T08:04:00Z", "cancelled": false],
             "mode": "BUS", "realTime": true, "headsign": "Center", "routeShortName": "175", "routeColor": "ff0000", "tripId": "t1"],
            ["place": ["departure": "2027-01-15T08:10:00Z", "scheduledDeparture": "2027-01-15T08:10:00Z", "cancelled": true],
             "mode": "TRAM", "realTime": true, "routeShortName": "9", "tripId": "t2"],
            ["place": ["departure": "2027-01-15T08:20:00Z"], "mode": "SUBWAY", "realTime": false, "routeShortName": "M1", "tripId": "t3"],
            ["place": [:], "mode": "BUS"],
        ]]
        let board = TransitLive.parseDepartures(json)
        XCTAssertEqual(board.count, 3, "a row without a time is dropped")
        XCTAssertEqual(board[0].delayMinutes, 3)
        XCTAssertEqual(board[0].colorHex, "ff0000")
        XCTAssertTrue(board[1].cancelled)
        XCTAssertNil(board[2].delayMinutes, "no live data, no delay")
        XCTAssertEqual(board[2].mode, .subway)
    }

    // MARK: Freshness

    func testLiveWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(LivePolicy.isLive(departure: now.addingTimeInterval(-9 * 60), now: now))
        XCTAssertFalse(LivePolicy.isLive(departure: now.addingTimeInterval(-11 * 60), now: now))
        XCTAssertTrue(LivePolicy.isLive(departure: now.addingTimeInterval(179 * 60), now: now))
        XCTAssertFalse(LivePolicy.isLive(departure: now.addingTimeInterval(181 * 60), now: now))
    }

    func testCacheAgeAndBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LivePolicy.cacheAge(for: now, isNow: true, now: now), 60)
        XCTAssertEqual(LivePolicy.cacheAge(for: now.addingTimeInterval(3_600), isNow: false, now: now), 90)
        XCTAssertEqual(LivePolicy.cacheAge(for: now.addingTimeInterval(5 * 86_400), isNow: false, now: now), 30 * 86_400)
        XCTAssertEqual(LivePolicy.bucketSeconds(for: now.addingTimeInterval(600), isNow: false, now: now), 300)
        XCTAssertEqual(LivePolicy.bucketSeconds(for: now.addingTimeInterval(5 * 86_400), isNow: false, now: now), 900)
    }

    func testCacheKeysAreVersionedAndBucketed() {
        let a = CLLocationCoordinate2D(latitude: 52.2, longitude: 21.0)
        let b = CLLocationCoordinate2D(latitude: 52.3, longitude: 21.1)
        let t = Date(timeIntervalSince1970: 1_000_000)
        let fifteen = TransitRouter.cacheKey(from: a, to: b, instant: t, arriveBy: false)
        XCTAssertTrue(fifteen.hasPrefix("v2|"))
        XCTAssertNotEqual(fifteen, TransitRouter.cacheKey(from: a, to: b, instant: t, arriveBy: false, bucketSeconds: 300))
        XCTAssertNotEqual(TransitRouter.cacheKey(from: a, to: b, instant: t, arriveBy: false, bucketSeconds: 300),
                          TransitRouter.cacheKey(from: a, to: b, instant: t.addingTimeInterval(400), arriveBy: false, bucketSeconds: 300))
    }
}

final class GateTests: XCTestCase {
    func testCancelledWaiterLeavesTheQueue() async throws {
        let gate = RequestGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("the cancelled waiter should have thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await gate.leave()
        try await gate.enter()          // the slot was not lost to the cancelled waiter
        await gate.leave()
    }

    func testWaitersAreServedInOrderAsSlotsFree() async throws {
        let gate = RequestGate(limit: 1)
        try await gate.enter()
        let order = OrderBox()
        let first = Task { try await gate.enter(); await order.add(1); await gate.leave() }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { try await gate.enter(); await order.add(2); await gate.leave() }
        try await Task.sleep(for: .milliseconds(30))
        await gate.leave()
        _ = try await first.value
        _ = try await second.value
        let seen = await order.values
        XCTAssertEqual(seen, [1, 2])
    }

    func testMapKitThrottleAllowsABurstThenWaits() async {
        let throttle = MapKitThrottle(perMinute: 2)
        let one = await throttle.acquire()
        let two = await throttle.acquire()
        XCTAssertTrue(one && two)
        let third = Task { await throttle.acquire() }
        try? await Task.sleep(for: .milliseconds(100))
        third.cancel()
        let result = await third.value
        XCTAssertFalse(result, "the third call has to wait; cancelling gives up")
    }

    func testCoolDownAfterAServerError() async {
        let network = TransitNetwork()
        await network.note(NetError.badStatus(503))
        do {
            try await network.enter()
            XCTFail("a busy service should not be asked again at once")
        } catch {
            XCTAssertTrue(error is TransitNetwork.Failure)
        }
        let fine = TransitNetwork()
        await fine.note(NetError.badStatus(404))
        do {
            try await fine.enter()
            await fine.leave()
        } catch {
            XCTFail("a 404 is no reason to stop asking")
        }
    }
}

private actor OrderBox {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}

final class DiagnosticsTests: XCTestCase {
    func testNewestFirstAndCapped() {
        let log = Diagnostics()
        for index in 0..<(Diagnostics.capacity + 5) {
            log.record(service: "host\(index)", message: "failed")
        }
        XCTAssertEqual(log.entries.count, Diagnostics.capacity)
        XCTAssertEqual(log.entries.first?.service, "host\(Diagnostics.capacity + 4)")
        XCTAssertEqual(log.entries.last?.service, "host5")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testReportListsEntries() {
        let log = Diagnostics()
        log.record(service: "api.transitous.org", message: "The server answered with status 503.")
        let text = log.report(appVersion: "1.0", system: "iOS 26")
        XCTAssertTrue(text.contains("api.transitous.org"))
        XCTAssertTrue(text.contains("status 503"))
        XCTAssertTrue(text.hasPrefix("Trip Planner 1.0 on iOS 26"))
        XCTAssertEqual(Diagnostics.service(for: URL(string: "https://overpass-api.de/api/interpreter?data=x")), "overpass-api.de")
    }

    func testWallClock() {
        let day = Calendar.current.startOfDay(for: Date())
        let date = WallClock.date(on: day, minute: 14 * 60 + 5)
        XCTAssertEqual(date.map { WallClock.minute(of: $0) }, 14 * 60 + 5)
        XCTAssertEqual(WallClock.date(on: day, minute: 99_999).map { WallClock.minute(of: $0) }, 23 * 60 + 59, "clamped to the day")
    }
}

final class OfflinePlannerTests: XCTestCase {
    private let hotel = CLLocationCoordinate2D(latitude: 52.2300, longitude: 21.0100)
    private func spot(_ east: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 52.2300, longitude: 21.0100 + east) }
    private let day1 = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func stops(_ names: String...) -> [OfflineStop] {
        names.enumerated().map { index, name in
            OfflineStop(name: name, coordinate: spot(Double(index + 1) * 0.01), plannedMinute: nil, durationMinutes: 60)
        }
    }

    func testTripFactsAndOneStopInfoPerStop() {
        let tasks = OfflinePlanner.tasks(days: [OfflineDay(date: day1, hotel: hotel, stops: stops("A", "B"))], transit: false)
        XCTAssertEqual(tasks.map(\.kind), ["timeZone", "holidays", "practicalInfo", "stopInfo", "stopInfo"])
    }

    func testWithPublicTransportEveryLegIsPrefetchedOnce() {
        let days = [OfflineDay(date: day1, hotel: hotel, stops: stops("A", "B")),
                    OfflineDay(date: day1.addingTimeInterval(86_400), hotel: hotel, stops: stops("C"))]
        let tasks = OfflinePlanner.tasks(days: days, transit: true)
        XCTAssertEqual(tasks.filter { $0.kind == "route" }.count, 3, "hotel to A, A to B, hotel to C")
        XCTAssertEqual(tasks.filter { $0.kind == "stopInfo" }.count, 3)
        XCTAssertTrue(tasks.contains { $0.kind == "transitGuide" })
        XCTAssertEqual(tasks.filter { $0.kind == "route" }.map(\.label), ["Hotel → A", "A → B", "Hotel → C"])
    }

    func testWithoutAHotelThereIsNoHotelLeg() {
        let tasks = OfflinePlanner.tasks(days: [OfflineDay(date: day1, hotel: nil, stops: stops("A", "B"))], transit: true)
        XCTAssertEqual(tasks.filter { $0.kind == "route" }.map(\.label), ["A → B"])
    }

    func testTheHotelLegArrivesOnTimeAndLaterLegsLeaveWhenTheStopEnds() {
        var first = stops("A", "B")
        first[0].plannedMinute = 10 * 60
        first[0].durationMinutes = 90
        let tasks = OfflinePlanner.tasks(days: [OfflineDay(date: day1, hotel: hotel, stops: first)], transit: true)
        let routes: [(minute: Int, arriveBy: Bool)] = tasks.compactMap { task in
            if case .route(_, _, _, let minute, let arriveBy, _) = task { return (minute, arriveBy) }
            return nil
        }
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].minute, 10 * 60)
        XCTAssertTrue(routes[0].arriveBy)
        XCTAssertEqual(routes[1].minute, 11 * 60 + 30, "A ends at 11:30")
        XCTAssertFalse(routes[1].arriveBy)
    }

    func testTheSameLegTwiceIsAskedForOnce() {
        let twin = [OfflineDay(date: day1, hotel: hotel, stops: stops("A")), OfflineDay(date: day1, hotel: hotel, stops: stops("A"))]
        XCTAssertEqual(OfflinePlanner.tasks(days: twin, transit: true).filter { $0.kind == "route" }.count, 1)
    }
}
