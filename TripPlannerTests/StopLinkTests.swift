import XCTest
@testable import TripPlanner

final class StopLinkTests: XCTestCase {
    func testAStopWithAPositionOpensGoogleMapsCentredThere() throws {
        let stop = Stop(name: "Senso-ji", latitude: 35.7148, longitude: 139.7967)
        let url = try XCTUnwrap(stop.googleMapsURL)
        XCTAssertEqual(url.absoluteString, "https://www.google.com/maps/search/Senso-ji/@35.714800,139.796700,17z")
    }

    func testTheNameIsEscapedForTheAddress() throws {
        let stop = Stop(name: "Café & Bar/Terrasse", latitude: 47.37, longitude: 8.54)
        let url = try XCTUnwrap(stop.googleMapsURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.google.com/maps/search/Caf%C3%A9%20&%20Bar%2FTerrasse/@47.370000,8.540000"))
    }

    func testAStopWithoutAPositionIsSearchedByNameAndAddress() throws {
        let stop = Stop(name: "Hotel Sonne", latitude: 0, longitude: 0, address: "Bahnhofstrasse 1, Zürich")
        let url = try XCTUnwrap(stop.googleMapsURL)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "query" })?.value, "Hotel Sonne Bahnhofstrasse 1, Zürich")
        XCTAssertEqual(items?.first(where: { $0.name == "api" })?.value, "1")
    }
}
