import XCTest
import CoreLocation
@testable import TripPlanner

final class HotelSearchTests: XCTestCase {
    private func hotel(_ name: String, lat: Double = 38.72, lon: Double = -9.14,
                       lodging: Bool = true, rating: Double? = nil, reviews: Int? = nil,
                       distance: Double? = nil) -> HotelResult {
        HotelResult(id: "\(name)-\(lat)", name: name, address: "", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    distanceFromCenter: distance, phone: nil, website: nil, isLodging: lodging,
                    rating: rating, reviews: reviews)
    }

    func testNamesMatchIgnoringGenericWordsAndAccents() {
        XCTAssertTrue(HotelSearchService.similar("Hotel Sol Lisboa", "Sol Lisboa"))
        XCTAssertTrue(HotelSearchService.similar("The Pousada São João", "Pousada Sao Joao"))
        XCTAssertFalse(HotelSearchService.similar("Hotel Sol", "Hotel Luna"))
        XCTAssertFalse(HotelSearchService.similar("", "Hotel Sol"))
    }

    func testRelevanceRanksExactThenPrefixThenContains() {
        XCTAssertEqual(HotelSearchService.relevance(name: "Hotel Sol", query: "sol"), 3)
        XCTAssertEqual(HotelSearchService.relevance(name: "Solar do Castelo", query: "sol"), 2)
        XCTAssertEqual(HotelSearchService.relevance(name: "Casa Solmar", query: "sol"), 1)
        XCTAssertEqual(HotelSearchService.relevance(name: "Grand Palace", query: "sol"), 0)
    }

    func testMergeKeepsOneRowAndCombinesDetails() {
        let apple = hotel("Hotel Sol Lisboa")
        let rated = hotel("Sol Lisboa", lat: 38.7205, rating: 4.5, reviews: 820)
        let faraway = hotel("Sol Lisboa", lat: 39.5, rating: 3.0)

        let merged = HotelSearchService.merge([apple], with: [rated, faraway])

        XCTAssertEqual(merged.count, 2, "the one 100 m away is the same hotel, the other city is not")
        XCTAssertEqual(merged[0].rating, 4.5)
        XCTAssertEqual(merged[0].reviews, 820)
        XCTAssertEqual(merged[0].name, "Hotel Sol Lisboa", "the Apple Maps name is kept")
    }

    func testEnrichAddsRatingsWithoutAddingRows() {
        let results = [hotel("Hotel Sol Lisboa"), hotel("Casa Azul", lat: 38.75)]
        let ratings = [hotel("Sol Lisboa", rating: 4.2, reviews: 100), hotel("Unrelated", lat: 38.9, rating: 5)]

        let enriched = HotelSearchService.enrich(results, with: ratings)

        XCTAssertEqual(enriched.count, 2)
        XCTAssertEqual(enriched[0].rating, 4.2)
        XCTAssertNil(enriched[1].rating)
    }

    func testSortByBestMatchPutsTheNameFirstThenLodgingThenDistance() {
        let results = [
            hotel("Grand Palace", lodging: true, distance: 100),
            hotel("Sol Street 5", lodging: false, distance: 50),
            hotel("Hotel Sol", lodging: true, distance: 3_000),
        ]
        let sorted = HotelSearchService.sorted(results, by: .bestMatch, query: "sol")
        XCTAssertEqual(sorted.map(\.name), ["Hotel Sol", "Sol Street 5", "Grand Palace"])
    }

    func testSortClosestAndTopRated() {
        let results = [
            hotel("A", rating: 3.5, reviews: 10, distance: 900),
            hotel("B", rating: 4.8, reviews: 50, distance: 4_000),
            hotel("C", rating: nil, distance: 100),
            hotel("D", rating: 4.8, reviews: 900, distance: 2_000),
        ]
        XCTAssertEqual(HotelSearchService.sorted(results, by: .closest, query: "").map(\.name), ["C", "A", "D", "B"])
        XCTAssertEqual(HotelSearchService.sorted(results, by: .topRated, query: "").map(\.name), ["D", "B", "A", "C"])
    }

    func testLodgingNamesAreRecognised() {
        XCTAssertTrue(HotelSearchService.looksLikeLodging("Sunrise Hostel"))
        XCTAssertTrue(HotelSearchService.looksLikeLodging("Apartamentos Mar apartment"))
        XCTAssertFalse(HotelSearchService.looksLikeLodging("Rua Augusta 100"))
    }
}
