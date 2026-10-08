import XCTest
@testable import TripPlanner

final class ReceiptParserTests: XCTestCase {
    private let now: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 15
        return Calendar.current.date(from: parts)!
    }()

    private func day(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func testNumbersInEveryWritingStyle() {
        XCTAssertEqual(ReceiptParser.number("45,80"), 45.8)
        XCTAssertEqual(ReceiptParser.number("45.80"), 45.8)
        XCTAssertEqual(ReceiptParser.number("1 234,50"), 1234.5)
        XCTAssertEqual(ReceiptParser.number("1.234,50"), 1234.5)
        XCTAssertEqual(ReceiptParser.number("1,234.50"), 1234.5)
        XCTAssertEqual(ReceiptParser.amounts(in: "Kawa 12,00  Ciastko 9,50"), [12.0, 9.5])
    }

    func testADateIsNotAnAmount() {
        XCTAssertTrue(ReceiptParser.amounts(in: "14.10.2026 12:31").isEmpty)
        XCTAssertEqual(ReceiptParser.amounts(in: "14.10.2026  Razem 45,80"), [45.8])
    }

    func testPolishReceipt() {
        let text = """
        RESTAURACJA POD ZAMKIEM
        ul. Piwna 5, Warszawa
        NIP 525-000-00-00
        PARAGON FISKALNY
        2026-10-14 13:05
        Pierogi ruskie        32,00 A
        Barszcz               18,00 A
        Sprzedaż opodatkowana A 50,00
        Suma PTU A             3,70
        SUMA PLN              50,00
        Gotówka               100,00
        Reszta                 50,00
        """
        let result = ReceiptParser.parse(text, now: now)
        XCTAssertEqual(result.amount, 50.0)
        XCTAssertEqual(result.currency, "PLN")
        XCTAssertEqual(day(result.date), "2026-10-14")
        XCTAssertEqual(result.merchant, "Restauracja Pod Zamkiem")
        XCTAssertEqual(result.category, .food)
    }

    func testGermanReceipt() {
        let text = """
        Café Central
        Rechnung Nr. 1042
        14.10.2026
        2x Kaffee      7,80
        1x Apfelstrudel 5,90
        Zwischensumme  13,70
        MwSt 19%        2,19
        Gesamtbetrag EUR 13,70
        Trinkgeld         1,30
        """
        let result = ReceiptParser.parse(text, now: now)
        XCTAssertEqual(result.amount, 13.7)
        XCTAssertEqual(result.currency, "EUR")
        XCTAssertEqual(day(result.date), "2026-10-14")
        XCTAssertEqual(result.merchant, "Café Central")
    }

    func testEnglishReceiptWithTheAmountOnTheNextLine() {
        let text = """
        Warsaw Coffee Roasters
        14/10/2026
        Flat white   £4.20
        Croissant    £3.10
        Total
        £7.30
        Card
        """
        let result = ReceiptParser.parse(text, now: now)
        XCTAssertEqual(result.amount, 7.3)
        XCTAssertEqual(result.currency, "GBP")
    }

    func testWithoutATotalLineTheBiggestAmountIsUsed() {
        let result = ReceiptParser.parse("Taxi\n14.10.2026\n38,50 zł", now: now)
        XCTAssertEqual(result.amount, 38.5)
        XCTAssertEqual(result.currency, "PLN")
        XCTAssertEqual(result.category, .transport)
    }

    func testNothingReadableGivesNothing() {
        let result = ReceiptParser.parse("hello\nworld", now: now)
        XCTAssertNil(result.amount)
        XCTAssertNil(result.currency)
        XCTAssertNil(result.date)
    }

    func testImpossibleAndFarAwayDatesAreIgnored() {
        XCTAssertNil(ReceiptParser.parse("31.02.2026\nTotal 5,00", now: now).date)
        XCTAssertNil(ReceiptParser.parse("14.10.2019\nTotal 5,00", now: now).date)
        XCTAssertEqual(day(ReceiptParser.parse("14.10.26\nTotal 5,00", now: now).date), "2026-10-14")
    }
}
