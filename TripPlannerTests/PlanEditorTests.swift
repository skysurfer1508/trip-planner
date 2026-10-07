import XCTest
import CoreLocation
@testable import TripPlanner

final class PlanEditorTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)

    private func candidate(_ id: String, _ kind: DiscoverKind, east: Double = 0, score: Double = 0.5) -> PlanCandidate {
        PlanCandidate(id: id, name: "Place \(id)",
                      coordinate: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + east * 0.004),
                      kind: kind, score: score)
    }

    private func prefs() -> TripPreferences {
        var value = TripPreferences()
        value.days = 1
        value.group = .couple
        value.interests = [.sights, .food]
        return value
    }

    private func day(_ spec: [(String, DiscoverKind)]) -> PlannedDay {
        var entries: [PlanEditor.Entry] = []
        for (index, item) in spec.enumerated() {
            let place = candidate(item.0, item.1, east: Double(index))
            entries.append((place, PlanEditor.slot(for: place, among: entries)))
        }
        let stops = PlanEditor.reschedule(entries, startOverride: nil, prefs: prefs(), window: DayWindow())
        return PlannedDay(stops: stops, theme: "Test day")
    }

    private func ids(_ day: PlannedDay) -> [String] { day.stops.map { $0.candidate.id } }

    func testRemoveDropsTheStopAndKeepsTimesIncreasing() {
        let original = day([("A", .sights), ("L", .food), ("B", .sights), ("D", .food)])
        XCTAssertEqual(ids(original), ["A", "L", "B", "D"])

        let outcome = PlanEditor.apply([.remove("B")], to: original, pool: [], usedElsewhere: [],
                                       prefs: prefs(), window: DayWindow())

        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(ids(outcome.day), ["A", "L", "D"])
        let times = outcome.day.stops.map(\.startMinute)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(outcome.day.theme, "Test day")
    }

    func testReplaceUsesAFreePlaceAndRefusesOneUsedElsewhere() {
        let original = day([("A", .sights), ("L", .food)])
        let pool = [candidate("C", .sights, east: 3), candidate("X", .sights, east: 4)]

        let replaced = PlanEditor.apply([.replace("A", with: "C")], to: original, pool: pool, usedElsewhere: [],
                                        prefs: prefs(), window: DayWindow())
        XCTAssertEqual(ids(replaced.day), ["C", "L"])

        let refused = PlanEditor.apply([.replace("A", with: "X")], to: original, pool: pool, usedElsewhere: ["X"],
                                       prefs: prefs(), window: DayWindow())
        XCTAssertFalse(refused.changed)
        XCTAssertEqual(ids(refused.day), ["A", "L"])
        XCTAssertFalse(refused.notes.isEmpty)
    }

    func testUnknownIdsAreIgnored() {
        let original = day([("A", .sights)])
        let outcome = PlanEditor.apply([.remove("nope"), .add("ghost", after: nil)], to: original, pool: [],
                                       usedElsewhere: [], prefs: prefs(), window: DayWindow())
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(ids(outcome.day), ["A"])
    }

    func testAddedSightGoesBeforeDinner() {
        let original = day([("A", .sights), ("L", .food), ("B", .sights), ("D", .food)])
        let pool = [candidate("E", .sights, east: 5)]
        let outcome = PlanEditor.apply([.add("E", after: nil)], to: original, pool: pool, usedElsewhere: [],
                                       prefs: prefs(), window: DayWindow())
        XCTAssertEqual(ids(outcome.day), ["A", "L", "B", "E", "D"])
    }

    func testAddedFoodBecomesDinnerWhenThereIsALunch() {
        let original = day([("A", .sights), ("L", .food)])
        let pool = [candidate("F", .food, east: 6)]
        let outcome = PlanEditor.apply([.add("F", after: nil)], to: original, pool: pool, usedElsewhere: [],
                                       prefs: prefs(), window: DayWindow())
        XCTAssertEqual(ids(outcome.day), ["A", "L", "F"])
        XCTAssertEqual(outcome.day.stops.last?.slot, .dinner)
        XCTAssertGreaterThanOrEqual(outcome.day.stops.last?.startMinute ?? 0, 18 * 60 + 45)
    }

    func testAddAfterAGivenStop() {
        let original = day([("A", .sights), ("B", .sights)])
        let pool = [candidate("E", .sights, east: 5)]
        let outcome = PlanEditor.apply([.add("E", after: "A")], to: original, pool: pool, usedElsewhere: [],
                                       prefs: prefs(), window: DayWindow())
        XCTAssertEqual(ids(outcome.day), ["A", "E", "B"])
    }

    func testSetStartMovesTheWholeDayAndRejectsNonsense() {
        let original = day([("A", .sights), ("B", .sights)])
        let later = PlanEditor.apply([.setStart(10 * 60 + 30)], to: original, pool: [], usedElsewhere: [],
                                     prefs: prefs(), window: DayWindow())
        XCTAssertGreaterThanOrEqual(later.day.stops.first?.startMinute ?? 0, 10 * 60 + 30)
        XCTAssertEqual(later.day.startOverride, 10 * 60 + 30)

        let silly = PlanEditor.apply([.setStart(3 * 60)], to: original, pool: [], usedElsewhere: [],
                                     prefs: prefs(), window: DayWindow())
        XCTAssertFalse(silly.changed)
    }

    func testStopsThatNoLongerFitAreReported() {
        let original = day([("A", .sights)])
        var window = DayWindow()
        window.endMinute = 12 * 60
        let pool = (1...4).map { candidate("E\($0)", .sights, east: Double($0)) }
        let edits = pool.map { PlanEdit.add($0.id, after: nil) }

        let outcome = PlanEditor.apply(edits, to: original, pool: pool, usedElsewhere: [],
                                       prefs: prefs(), window: window)

        XCTAssertLessThan(outcome.day.stops.count, 5)
        XCTAssertTrue(outcome.notes.contains { $0.contains("left out") })
        XCTAssertTrue(outcome.day.stops.allSatisfy { $0.startMinute < 12 * 60 })
    }

    func testAlternativesAreUnusedPlacesOfTheSameKindNearestFirst() {
        let original = day([("A", .sights), ("L", .food)])
        let pool = [
            candidate("near", .sights, east: 0.2, score: 0.5),
            candidate("far", .sights, east: 30, score: 0.5),
            candidate("taken", .sights, east: 0.1, score: 0.9),
            candidate("meal", .food, east: 0.1),
        ]
        let options = PlanEditor.alternatives(for: original.stops[0], pool: pool, taken: ["taken"], prefs: prefs())
        XCTAssertEqual(options.map(\.id), ["near", "far"])
    }

    func testShuffleStaysInsidePlacesOtherDaysDoNotUse() {
        let original = day([("A", .sights), ("L", .food)])
        let pool = (0..<10).map { candidate("S\($0)", .sights, east: Double($0)) }
            + (0..<10).map { candidate("F\($0)", .food, east: Double($0)) }
        let blocked = Set(pool.prefix(5).map(\.id))
        var rng = SplitMix64(seed: 3)

        let fresh = PlanEditor.shuffle(original, pool: pool, usedElsewhere: blocked, prefs: prefs(),
                                       window: DayWindow(), center: center, using: &rng)

        XCTAssertFalse(fresh.stops.isEmpty)
        XCTAssertTrue(fresh.stops.allSatisfy { !blocked.contains($0.candidate.id) })
        XCTAssertEqual(fresh.theme, "Test day")
    }

    // MARK: AI answers to edits

    func testAiCommandsAreMappedAndUnknownIdsDropped() {
        let original = day([("A", .sights), ("L", .food)])
        let pool = [candidate("C", .sights, east: 3)]
        let prepared = DayEditService.prepare(instruction: "swap", day: original, dayNumber: 2, pool: pool,
                                              usedElsewhere: [], prefs: prefs(), destination: "Lisbon",
                                              window: DayWindow())
        XCTAssertEqual(prepared.stopAliases["s1"], "A")
        XCTAssertEqual(prepared.candidateAliases["p1"], "C")

        let response = DayEditResponse(summary: "ok", commands: [
            DayEditCommand(action: "replace", stop: "s1", candidate: "p1"),
            DayEditCommand(action: "remove", stop: "s9"),
            DayEditCommand(action: "add", candidate: "p7"),
            DayEditCommand(action: "set_start", time: "09:30"),
            DayEditCommand(action: "explode", stop: "s1"),
        ])
        let edits = DayEditService.edits(from: response, prepared: prepared)
        XCTAssertEqual(edits, [.replace("A", with: "C"), .setStart(9 * 60 + 30)])
    }

    func testPreparedRequestOnlyOffersUnusedPlacesNotAlreadyInTheDay() {
        let original = day([("A", .sights)])
        let pool = [candidate("A", .sights), candidate("B", .sights, east: 2), candidate("C", .sights, east: 3)]
        let prepared = DayEditService.prepare(instruction: "more", day: original, dayNumber: 1, pool: pool,
                                              usedElsewhere: ["C"], prefs: prefs(), destination: "",
                                              window: DayWindow())
        XCTAssertEqual(prepared.candidateAliases.values.sorted(), ["B"])
    }

    func testGeminiAnswerIsParsed() {
        let json: [String: Any] = [
            "summary": "Swapped the museum.",
            "edits": [
                ["action": "replace", "stop": "s2", "candidate": "p4", "after": "", "time": ""],
                ["action": "", "stop": "s1"],
            ],
        ]
        let response = DayEditJSON.parse(json)
        XCTAssertEqual(response.summary, "Swapped the museum.")
        XCTAssertEqual(response.commands.count, 1)
        XCTAssertEqual(response.commands[0].candidate, "p4")
    }

    func testTimeTextIsParsed() {
        XCTAssertEqual(DayEditService.minutes(from: "14:05"), 14 * 60 + 5)
        XCTAssertNil(DayEditService.minutes(from: "later"))
        XCTAssertNil(DayEditService.minutes(from: "25:00"))
    }
}
