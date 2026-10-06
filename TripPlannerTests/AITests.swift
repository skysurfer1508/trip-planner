import XCTest
@testable import TripPlanner

final class AITests: XCTestCase {
    func testItineraryJSONMapsDaysStopsAndTimes() {
        let json: [String: Any] = [
            "days": [
                [
                    "label": "Day 1",
                    "date": "2026-06-05",
                    "stops": [
                        ["title": "Belém Tower, Lisbon", "time": "09:30", "notes": "Buy tickets online", "category": "sight"],
                        ["title": "  ", "time": "10:00"],
                        ["title": "Time Out Market", "time": "bad", "category": "food"],
                    ],
                ],
                ["label": "Day 2", "stops": []],
            ],
        ]
        let result = ItineraryJSON.parse(json)

        XCTAssertEqual(result.days.count, 1, "days without stops are dropped")
        let stops = result.days[0].stops
        XCTAssertEqual(stops.map(\.title), ["Belém Tower, Lisbon", "Time Out Market"])
        XCTAssertEqual(stops[0].hour, 9)
        XCTAssertEqual(stops[0].minute, 30)
        XCTAssertEqual(stops[0].category, .sight)
        XCTAssertNil(stops[1].hour)
        XCTAssertNotNil(result.days[0].date)
    }

    func testChunkerKeepsEverythingAndRespectsLimit() {
        let day = String(repeating: "10:00 Some place with a long description. ", count: 14)
        let text = (1...8).map { "Day \($0)\n\(day)" }.joined(separator: "\n")
        let chunks = TextChunker.chunks(text, limit: 1000)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1000 })
        let joined = chunks.joined(separator: "\n")
        XCTAssertEqual(joined.components(separatedBy: "Day ").count, text.components(separatedBy: "Day ").count)
    }

    func testChunkerStartsNewChunkAtDayHeading() {
        let filler = String(repeating: "x", count: 700)
        let text = "Day 1\n\(filler)\nDay 2\n\(filler)"
        let chunks = TextChunker.chunks(text, limit: 1000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[1].hasPrefix("Day 2"))
    }

    func testSecondChunkerCaseShortTextIsOneChunk() {
        XCTAssertEqual(TextChunker.chunks("Day 1\n10:00 Museum").count, 1)
        XCTAssertEqual(TextChunker.chunks("   ").count, 0)
    }
}
