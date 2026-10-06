import XCTest
import CoreLocation
@testable import TripPlanner

final class TripLogisticsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))!
    }

    private let hotelLocation = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)

    private func bookings() -> [BookingInfo] {
        [
            BookingInfo(kind: .arrivalFlight, title: "LH 1234", placeName: "LIS", start: date(5, 12), end: date(5, 14, 30),
                        bufferMinutes: 120, coordinate: nil, remind: true),
            BookingInfo(kind: .hotel, title: "Hotel Sol", placeName: "Hotel Sol", start: date(5, 15), end: date(8, 11),
                        bufferMinutes: 0, coordinate: hotelLocation, remind: true),
            BookingInfo(kind: .departureFlight, title: "LH 1235", placeName: "LIS", start: date(8, 18, 20), end: date(8, 22),
                        bufferMinutes: 180, coordinate: nil, remind: true),
        ]
    }

    func testArrivalDayStartsAfterLandingPlusBuffer() {
        let window = TripLogistics.window(for: date(5, 0), bookings: bookings(), calendar: calendar)
        XCTAssertEqual(window.startMinute, 14 * 60 + 30 + 120)
        XCTAssertNil(window.endMinute)
        XCTAssertTrue(window.items.contains { $0.text.hasPrefix("Land") })
        XCTAssertTrue(window.items.contains { $0.text.hasPrefix("Check in") })
    }

    func testDepartureDayEndsBeforeTheAirportTrip() {
        let window = TripLogistics.window(for: date(8, 0), bookings: bookings(), calendar: calendar)
        XCTAssertEqual(window.endMinute, 18 * 60 + 20 - 180)
        XCTAssertNil(window.startMinute)
        XCTAssertTrue(window.items.contains { $0.text.hasPrefix("Check out") })
        XCTAssertTrue(window.items.contains { $0.text == "Leave for the airport" })
    }

    func testHotelIsTheAnchorOnlyWhileYouStay() {
        for day in 5...8 {
            let window = TripLogistics.window(for: date(day, 0), bookings: bookings(), calendar: calendar)
            XCTAssertNotNil(window.anchor, "day \(day)")
        }
        XCTAssertNil(TripLogistics.window(for: date(4, 0), bookings: bookings(), calendar: calendar).anchor)
        XCTAssertNil(TripLogistics.window(for: date(9, 0), bookings: bookings(), calendar: calendar).anchor)
    }

    func testMiddleDayIsOpen() {
        let window = TripLogistics.window(for: date(6, 0), bookings: bookings(), calendar: calendar)
        XCTAssertNil(window.startMinute)
        XCTAssertNil(window.endMinute)
        XCTAssertTrue(window.items.isEmpty)
    }

    func testNoBookingsMeansNoLimits() {
        XCTAssertTrue(TripLogistics.window(for: date(5, 0), bookings: [], calendar: calendar).isEmpty)
    }
}
