import XCTest
import SwiftData
@testable import TripPlanner

@MainActor
final class SyncTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self,
                           ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// The device's calendar, like the app uses it: the trip's days are built with it too.
    private let codec = SyncCodec()

    private func makeTrip(in context: ModelContext) -> Trip {
        let start = codec.parseDay("2026-11-05")!
        let trip = Trip(name: "Warsaw", destination: "Poland", startDate: start, endDate: codec.parseDay("2026-11-07")!)
        context.insert(trip)
        trip.syncDays()
        return trip
    }

    private func response(tripID: String = "T", revision: Int = 5, conflicts: [SyncConflict] = [], changes: [SyncServerChange] = []) -> SyncResponse {
        SyncResponse(tripID: tripID, revision: revision, conflicts: conflicts, changes: changes)
    }

    private func serverStop(_ id: String, name: String, day: String, order: Int = 0) -> SyncServerChange {
        var fields = SyncFields()
        fields["name"] = .string(name)
        fields["day"] = .string(day)
        fields["sort_order"] = .number(Double(order))
        fields["latitude"] = .number(52.2)
        fields["longitude"] = .number(21.0)
        return SyncServerChange(kind: "stop", id: id, deleted: false, fields: fields)
    }

    // MARK: Values and dates

    func testValuesCompareLikeTheServerDoes() {
        XCTAssertTrue(SyncValue.string("").matches(.null))
        XCTAssertTrue(SyncValue.number(1).matches(.number(1.0)))
        XCTAssertFalse(SyncValue.string("a").matches(.string("b")))
        XCTAssertFalse(SyncValue.bool(true).matches(.bool(false)))
    }

    func testValuesSurviveJSON() throws {
        let fields: SyncFields = ["a": .null, "b": .bool(true), "c": .number(2.5), "d": .string("x")]
        let data = try JSONEncoder().encode(fields)
        XCTAssertEqual(try JSONDecoder().decode(SyncFields.self, from: data), fields)
        let decoded = try JSONDecoder().decode(SyncFields.self, from: Data(#"{"n":1,"f":false,"s":null}"#.utf8))
        XCTAssertEqual(decoded["n"], .number(1))
        XCTAssertEqual(decoded["f"], .bool(false))
        XCTAssertEqual(decoded["s"], .null)
    }

    func testWallClockTimesRoundTrip() {
        let date = codec.parseTime("2026-11-06T10:15")!
        XCTAssertEqual(codec.timeString(date), "2026-11-06T10:15")
        XCTAssertEqual(codec.dayString(codec.parseDay("2026-11-06")!), "2026-11-06")
    }

    func testCodecSendsOnlyWhatTheWebsiteAccepts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Old Town", latitude: 999, longitude: 21, address: "")
        stop.website = "not a link"
        stop.durationMinutes = 99_999
        trip.sortedDays[0].append(stop)
        let fields = codec.fields(of: stop, dayDate: trip.sortedDays[0].date)
        XCTAssertEqual(fields["website"], .string(""))
        XCTAssertEqual(fields["duration_minutes"], .number(1440))
        XCTAssertEqual(fields["latitude"], .number(0))
        XCTAssertEqual(fields["day"], .string("2026-11-05"))
        XCTAssertEqual(fields["planned_time"], .null)
    }

    func testABookingWithoutPositionSendsNone() throws {
        let booking = Booking(kind: .hotel, title: "Hotel", startDate: Date(), endDate: Date())
        XCTAssertNil(codec.fields(of: booking)["latitude"])
        booking.latitude = 52.2
        booking.longitude = 21.0
        booking.hasCoordinate = true
        XCTAssertEqual(codec.fields(of: booking)["latitude"], .number(52.2))
    }

    // MARK: What the phone sends

    func testSnapshotGivesEveryItemAnIDOnce() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Old Town", latitude: 52.25, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        XCTAssertTrue(stop.syncID.isEmpty)
        let first = SyncEngine.snapshot(of: trip, codec: codec)
        let id = stop.syncID
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(first.items["stop:" + id])
        _ = SyncEngine.snapshot(of: trip, codec: codec)
        XCTAssertEqual(stop.syncID, id)
        XCTAssertEqual(first.days.count, 3)
    }

    func testNothingChangedMeansNothingToSend() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        trip.sortedDays[0].append(Stop(name: "Old Town", latitude: 52.25, longitude: 21.01))
        let snapshot = SyncEngine.snapshot(of: trip, codec: codec)
        XCTAssertTrue(SyncEngine.changes(current: snapshot, base: snapshot.flat).isEmpty)
    }

    func testChangesAreSentPerFieldWithTheStartingValue() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Old Town", latitude: 52.25, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        let base = SyncEngine.snapshot(of: trip, codec: codec).flat

        stop.notes = "Bring cash"
        trip.budget = 500
        let added = Stop(name: "Castle", latitude: 52.24, longitude: 21.01)
        trip.sortedDays[1].append(added)
        trip.sortedDays[2].notes = "Fly home"

        let changes = SyncEngine.changes(current: SyncEngine.snapshot(of: trip, codec: codec), base: base)
        let byKey = Dictionary(uniqueKeysWithValues: changes.map { ($0.kind + ":" + $0.id, $0) })
        XCTAssertEqual(byKey["stop:" + stop.syncID]?.fields?.keys.sorted(), ["notes"])
        XCTAssertEqual(byKey["stop:" + stop.syncID]?.fields?["notes"]?.base, .string(""))
        XCTAssertEqual(byKey["stop:" + stop.syncID]?.fields?["notes"]?.new, .string("Bring cash"))
        XCTAssertEqual(byKey["trip:trip"]?.fields?["budget"]?.new, .number(500))
        XCTAssertEqual(byKey["stop:" + added.syncID]?.op, "upsert")
        XCTAssertEqual(byKey["stop:" + added.syncID]?.fields?["day"]?.new, .string("2026-11-06"))
        XCTAssertEqual(byKey["day:2026-11-07"]?.fields?["notes"]?.new, .string("Fly home"))
    }

    func testADeletedItemIsSentAsDeletion() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Old Town", latitude: 52.25, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        let base = SyncEngine.snapshot(of: trip, codec: codec).flat
        let id = stop.syncID
        trip.sortedDays[0].remove(stop)
        let changes = SyncEngine.changes(current: SyncEngine.snapshot(of: trip, codec: codec), base: base)
        XCTAssertEqual(changes.filter { $0.op == "delete" }.map { $0.id }, [id])
    }

    // MARK: What the server sends

    func testNewThingsFromTheServerAppearOnThePhone() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        var tripFields = SyncFields()
        tripFields["budget"] = .number(800)
        var expense = SyncFields()
        expense["title"] = .string("Dinner")
        expense["amount"] = .number(32.5)
        expense["currency_code"] = .string("PLN")
        expense["category_raw"] = .string("food")
        expense["date"] = .string("2026-11-06")
        let answer = response(changes: [
            SyncServerChange(kind: "trip", id: "T", deleted: false, fields: tripFields),
            serverStop("S-1", name: "Castle", day: "2026-11-06"),
            SyncServerChange(kind: "expense", id: "E-1", deleted: false, fields: expense),
        ])
        SyncEngine.apply(answer, to: trip, context: context, pushed: pushed, oldBase: [:], codec: codec)

        XCTAssertEqual(trip.budget, 800)
        XCTAssertEqual(trip.sortedDays[1].stops.map(\.name), ["Castle"])
        XCTAssertEqual(trip.sortedDays[1].stops.first?.syncID, "S-1")
        XCTAssertEqual(trip.expenses.first?.title, "Dinner")
        XCTAssertEqual(trip.expenses.first?.amount, 32.5)
        XCTAssertEqual(trip.syncRevision, 5)
        XCTAssertNotNil(trip.syncedAt)
        // the base now contains what both sides have, so the next sync has nothing to send
        let after = SyncEngine.snapshot(of: trip, codec: codec)
        XCTAssertTrue(SyncEngine.changes(current: after, base: SyncEngine.decodeBase(trip.syncBase)).isEmpty)
    }

    func testAStopMovedToAnotherDayOnTheServerMovesOnThePhone() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Castle", latitude: 52.24, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        stop.syncID = "S-1"
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        SyncEngine.apply(response(changes: [serverStop("S-1", name: "Castle", day: "2026-11-07")]), to: trip, context: context,
                         pushed: pushed, oldBase: pushed.flat, codec: codec)
        XCTAssertTrue(trip.sortedDays[0].stops.isEmpty)
        XCTAssertEqual(trip.sortedDays[2].stops.map(\.syncID), ["S-1"])
    }

    func testServerDeletionRemovesTheItem() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Castle", latitude: 52.24, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        stop.syncID = "S-1"
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        SyncEngine.apply(response(changes: [SyncServerChange(kind: "stop", id: "S-1", deleted: true, fields: nil)]), to: trip, context: context,
                         pushed: pushed, oldBase: pushed.flat, codec: codec)
        XCTAssertTrue(trip.sortedDays[0].stops.isEmpty)
        XCTAssertNil(SyncEngine.decodeBase(trip.syncBase)["stop:S-1"])
    }

    func testAConflictTakesTheServersValue() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Castle", latitude: 52.24, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        stop.syncID = "S-1"
        stop.notes = "mine"
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        let conflict = SyncConflict(kind: "stop", id: "S-1", label: "Castle", field: "notes", server: .string("theirs"), app: .string("mine"))
        SyncEngine.apply(response(conflicts: [conflict]), to: trip, context: context, pushed: pushed, oldBase: [:], codec: codec)
        XCTAssertEqual(stop.notes, "theirs")
    }

    func testSomethingChangedDuringTheRequestIsKeptAndSentNextTime() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let stop = Stop(name: "Castle", latitude: 52.24, longitude: 21.01)
        trip.sortedDays[0].append(stop)
        stop.syncID = "S-1"
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        let oldBase = pushed.flat
        stop.notes = "typed while syncing"                       // after the data was captured
        SyncEngine.apply(response(changes: [serverStop("S-1", name: "Castle (server)", day: "2026-11-05")]), to: trip, context: context,
                         pushed: pushed, oldBase: oldBase, codec: codec)
        XCTAssertEqual(stop.name, "Castle")
        XCTAssertEqual(stop.notes, "typed while syncing")
        let next = SyncEngine.changes(current: SyncEngine.snapshot(of: trip, codec: codec), base: SyncEngine.decodeBase(trip.syncBase))
        XCTAssertEqual(next.first { $0.id == "S-1" }?.fields?["notes"]?.new, .string("typed while syncing"))
    }

    func testAnItemCreatedDuringTheRequestIsNotMarkedAsKnown() throws {
        let context = try makeContainer().mainContext
        let trip = makeTrip(in: context)
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        let late = Stop(name: "Late", latitude: 52.2, longitude: 21.0)
        trip.sortedDays[0].append(late)
        SyncEngine.apply(response(), to: trip, context: context, pushed: pushed, oldBase: pushed.flat, codec: codec)
        let next = SyncEngine.changes(current: SyncEngine.snapshot(of: trip, codec: codec), base: SyncEngine.decodeBase(trip.syncBase))
        XCTAssertEqual(next.filter { $0.kind == "stop" }.count, 1)
    }

    func testSignInChallengeIsBase64URLOfTheVerifiersHash() {
        // RFC 7636 appendix B
        XCTAssertEqual(SyncService.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
