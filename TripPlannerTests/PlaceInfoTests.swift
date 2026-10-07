import XCTest
import CoreLocation
@testable import TripPlanner

final class PlaceInfoTests: XCTestCase {
    func testLookupIsSkippedForGeneratedStops() {
        XCTAssertFalse(PlaceInfoService.shouldLookUp(name: "Check in · Hotel Sol", category: .hotel))
        XCTAssertFalse(PlaceInfoService.shouldLookUp(name: "Land · LH 1234", category: .transport))
        XCTAssertFalse(PlaceInfoService.shouldLookUp(name: "Leave for the airport", category: .transport))
        XCTAssertFalse(PlaceInfoService.shouldLookUp(name: "AB", category: .sight))
        XCTAssertTrue(PlaceInfoService.shouldLookUp(name: "Belém Tower", category: .sight))
    }

    func testPickTitlePrefersAMatchingNameOverACloserArticle() {
        let hits = [WikiHit(title: "Some Other Building", distance: 10), WikiHit(title: "Belém Tower", distance: 120)]
        XCTAssertEqual(PlaceInfoService.pickTitle(from: hits, name: "Belem Tower", allowNearest: true), "Belém Tower")
    }

    func testSightsMayUseTheArticleTaggedRightThere() {
        let hits = [WikiHit(title: "Belém Tower", distance: 25)]
        XCTAssertEqual(PlaceInfoService.pickTitle(from: hits, name: "Torre de Belém", allowNearest: true), "Belém Tower")
    }

    func testRestaurantsDoNotGetAnUnrelatedNeighbourArticle() {
        let hits = [WikiHit(title: "Jerónimos Monastery", distance: 25)]
        XCTAssertNil(PlaceInfoService.pickTitle(from: hits, name: "Pastéis Corner Cafe", allowNearest: false))
    }

    func testFarArticlesAreNotUsedAsTheNearestFallback() {
        let hits = [WikiHit(title: "Some Square", distance: 300)]
        XCTAssertNil(PlaceInfoService.pickTitle(from: hits, name: "Praça Nova", allowNearest: true))
    }

    func testShortenCutsAtASentence() {
        let sentence = "The tower is a fortified landmark on the river bank. "
        let long = String(repeating: sentence, count: 20)
        let short = PlaceInfoService.shorten(long, limit: 200)
        XCTAssertLessThanOrEqual(short.count, 201)
        XCTAssertTrue(short.hasSuffix("."))
        XCTAssertEqual(PlaceInfoService.shorten("Short text."), "Short text.")
    }

    func testParsesGeosearchAndSortsByDistance() {
        let json: [String: Any] = [
            "query": ["geosearch": [
                ["pageid": 1, "title": "Far", "lat": 1.0, "lon": 1.0, "dist": 320.5],
                ["pageid": 2, "title": "Near", "lat": 1.0, "lon": 1.0, "dist": 12.0],
            ]],
        ]
        let hits = WikipediaService.parseGeosearch(json)
        XCTAssertEqual(hits.map(\.title), ["Near", "Far"])
        XCTAssertTrue(WikipediaService.parseGeosearch([:]).isEmpty)
    }

    func testThumbnailSizeIsChangedInTheURL() {
        let summary = WikiSummary(title: "T", extract: "x",
                                  thumbnail: URL(string: "https://upload.wikimedia.org/thumb/a/ab/T.jpg/320px-T.jpg"),
                                  pageURL: nil, coordinate: nil, type: "standard")
        XCTAssertEqual(summary.thumbnailURL(width: 640)?.absoluteString,
                       "https://upload.wikimedia.org/thumb/a/ab/T.jpg/640px-T.jpg")
    }
}
