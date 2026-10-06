import XCTest
import CoreLocation
@testable import TripPlanner

final class FlightLookupTests: XCTestCase {
    func testNormalizeAcceptsCommonFormats() {
        XCTAssertEqual(FlightLookupService.normalize("LH 1234"), "LH1234")
        XCTAssertEqual(FlightLookupService.normalize("lh1234"), "LH1234")
        XCTAssertEqual(FlightLookupService.normalize(" u2 5678 "), "U25678")
        XCTAssertEqual(FlightLookupService.normalize("BA 12A"), "BA12A")
    }

    func testNormalizeRejectsOtherInput() {
        XCTAssertNil(FlightLookupService.normalize(""))
        XCTAssertNil(FlightLookupService.normalize("Lufthansa"))
        XCTAssertNil(FlightLookupService.normalize("L1"))
        XCTAssertNil(FlightLookupService.normalize("LH 123456"))
    }

    func testAirlineNameComesFromTheFlightNumber() {
        XCTAssertEqual(AirlineDirectory.name(forFlightNumber: "LH 1234"), "Lufthansa")
        XCTAssertEqual(AirlineDirectory.name(forFlightNumber: "fr 99"), "Ryanair")
        XCTAssertNil(AirlineDirectory.name(forFlightNumber: "ZZ 1"))
        XCTAssertNil(AirlineDirectory.name(forFlightNumber: "hello"))
    }

    private func sample() -> [[String: Any]] {
        [[
            "number": "LH 1234",
            "status": "Expected",
            "airline": ["name": "Lufthansa", "iata": "LH"],
            "departure": [
                "airport": ["iata": "FRA", "name": "Frankfurt am Main", "municipalityName": "Frankfurt",
                            "countryCode": "DE", "location": ["lat": 50.0333, "lon": 8.5706]],
                "scheduledTime": ["utc": "2026-06-05 08:00Z", "local": "2026-06-05 10:00+02:00"],
                "terminal": "1",
            ],
            "arrival": [
                "airport": ["iata": "LIS", "name": "Lisbon Humberto Delgado", "municipalityName": "Lisbon",
                            "countryCode": "PT", "location": ["lat": 38.7742, "lon": -9.1342]],
                "scheduledTime": ["utc": "2026-06-05 11:30Z", "local": "2026-06-05 12:30+01:00"],
                "terminal": "2",
            ],
        ]]
    }

    func testParsesAirportsAndLocalTimes() throws {
        let legs = FlightLookupService.parse(sample())
        let leg = try XCTUnwrap(legs.first)

        XCTAssertEqual(leg.from.iata, "FRA")
        XCTAssertEqual(leg.to.iata, "LIS")
        XCTAssertEqual(leg.to.shortName, "Lisbon (LIS)")
        XCTAssertEqual(leg.arrivalTerminal, "2")
        XCTAssertTrue(leg.isInternational)

        let calendar = Calendar.current
        let departure = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: leg.departure)
        XCTAssertEqual([departure.day, departure.hour, departure.minute], [5, 10, 0])
        let arrival = calendar.dateComponents([.hour, .minute], from: leg.arrival)
        XCTAssertEqual([arrival.hour, arrival.minute], [12, 30])
    }

    func testParsesTheOlderTimeFieldAndSkipsBrokenRows() {
        var rows = sample()
        var departure = rows[0]["departure"] as! [String: Any]
        departure["scheduledTime"] = nil
        departure["scheduledTimeLocal"] = "2026-06-05 10:00+02:00"
        rows[0]["departure"] = departure
        rows.append(["number": "XX 1"])

        let legs = FlightLookupService.parse(rows)
        XCTAssertEqual(legs.count, 1)
    }

    func testBestLegIsTheOneTouchingTheDestination() {
        let lisbon = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)
        var first = FlightLookupService.parse(sample())[0]      // FRA -> LIS
        var second = first                                       // LIS -> OPO (continues north)
        second.from = first.to
        second.to = FlightAirport(iata: "OPO", name: "Porto", city: "Porto",
                                  coordinate: CLLocationCoordinate2D(latitude: 41.24, longitude: -8.68), countryCode: "PT")
        first.number = "A"
        second.number = "B"

        let arrival = FlightLookupService.bestLeg([second, first], kind: .arrivalFlight, near: lisbon)
        XCTAssertEqual(arrival?.number, "A", "the leg that lands in Lisbon")

        let departure = FlightLookupService.bestLeg([first, second], kind: .departureFlight, near: lisbon)
        XCTAssertEqual(departure?.number, "B", "the leg that leaves from Lisbon")
    }

    func testBuffersAreShorterForDomesticFlights() throws {
        var leg = try XCTUnwrap(FlightLookupService.parse(sample()).first)
        XCTAssertEqual(FlightLookupService.defaultBuffer(kind: .departureFlight, leg: leg), 180)
        leg.to.countryCode = "DE"
        XCTAssertEqual(FlightLookupService.defaultBuffer(kind: .departureFlight, leg: leg), 120)
        XCTAssertEqual(FlightLookupService.defaultBuffer(kind: .arrivalFlight, leg: leg), 90)
    }
}
