import XCTest
@testable import TripPlanner

final class ItineraryParserTests: XCTestCase {
    func testDaysTimesAndBullets() {
        let text = """
        Day 1
        09:30 Belém Tower
        11:00 - 12:30 Jerónimos Monastery
        Day 2
        • Time Out Market
        """
        let result = ItineraryParser.parse(text, tripRange: nil)

        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.days[0].stops.map(\.title), ["Belém Tower", "Jerónimos Monastery"])
        XCTAssertEqual(result.days[0].stops[0].hour, 9)
        XCTAssertEqual(result.days[0].stops[0].minute, 30)
        XCTAssertEqual(result.days[0].stops[1].hour, 11)
        XCTAssertEqual(result.days[1].stops.map(\.title), ["Time Out Market"])
    }

    func testLeadingTimeVariants() {
        XCTAssertEqual(ItineraryParser.leadingTime("9am Louvre")?.hour, 9)
        let afternoon = ItineraryParser.leadingTime("2:15 pm Lunch")
        XCTAssertEqual(afternoon?.hour, 14)
        XCTAssertEqual(afternoon?.minute, 15)
        XCTAssertEqual(ItineraryParser.leadingTime("12 am Midnight tour")?.hour, 0)
        XCTAssertEqual(ItineraryParser.leadingTime("10 Uhr Frühstück")?.hour, 10)
    }

    func testDatesAreNotTimes() {
        XCTAssertNil(ItineraryParser.leadingTime("10.06.2026 Arrival"))
    }

    func testIgnoresLinksAndBookingNumbers() {
        let text = """
        Day 1
        10:00 Museum
        https://example.com/tickets
        Booking reference ABC123
        """
        let result = ItineraryParser.parse(text, tripRange: nil)
        XCTAssertEqual(result.days.first?.stops.map(\.title), ["Museum"])
    }

    func testCategoryGuess() {
        XCTAssertEqual(ItineraryParser.guessCategory("Dinner at Trattoria Roma"), .food)
        XCTAssertEqual(ItineraryParser.guessCategory("Hotel check-in"), .hotel)
        XCTAssertEqual(ItineraryParser.guessCategory("Royal Palace"), .sight)
    }
}
