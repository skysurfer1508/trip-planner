import XCTest
import CoreLocation
import MapKit
@testable import TripPlanner

final class PlaceFinderTests: XCTestCase {
    private let warsaw = CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122)

    func testAccentsAndPolishLettersAreIgnored() {
        XCTAssertEqual(PlaceFinder.fold("Świętokrzyski Łódź Ørsted Straße"), "swietokrzyski lodz orsted strasse")
        XCTAssertGreaterThan(PlaceFinder.similarity("Swietokrzyski Bridge", "Most Świętokrzyski"), 0.7)
    }

    func testPartialAndLongerNamesStillMatch() {
        XCTAssertGreaterThan(PlaceFinder.similarity("Louvre", "Louvre Museum"), 0.7)
        XCTAssertGreaterThan(PlaceFinder.similarity("Palace of Culture and Science", "Pałac Kultury i Nauki"), 0.0)
        XCTAssertGreaterThan(PlaceFinder.similarity("Palace Culture Science", "Palace of Culture and Science"), 0.9)
    }

    func testSmallTyposMatch() {
        XCTAssertTrue(PlaceFinder.wordsMatch("colosseum", "colloseum"))
        XCTAssertTrue(PlaceFinder.wordsMatch("belem", "belém".folding(options: .diacriticInsensitive, locale: nil)))
        XCTAssertFalse(PlaceFinder.wordsMatch("tower", "flower"), "short words need to be exact")
    }

    func testDifferentPlacesDoNotMatch() {
        XCTAssertLessThan(PlaceFinder.similarity("Eiffel Tower", "Louvre Museum"), 0.2)
        XCTAssertLessThan(PlaceFinder.similarity("Old Town Square", "Central Station"), 0.3)
    }

    func testCloserPlaceWinsWithTheSameName() {
        let near = PlaceFinder.score(names: ["Castle"], placeName: "Castle", coordinate: warsaw,
                                     isPointOfInterest: true, center: warsaw)
        let far = PlaceFinder.score(names: ["Castle"], placeName: "Castle",
                                    coordinate: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
                                    isPointOfInterest: true, center: warsaw)
        XCTAssertGreaterThan(near.total, far.total + 0.2)
    }

    func testRankPrefersTheRightNameOverTheNearerWrongOne() {
        let right = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 52.24, longitude: 21.02)))
        right.name = "Royal Castle"
        let wrong = MKMapItem(placemark: MKPlacemark(coordinate: warsaw))
        wrong.name = "Cafe Zamek Pizza"
        let ranked = PlaceFinder.rank([wrong, right], query: "Royal Castle", center: warsaw)
        XCTAssertEqual(ranked.first?.item.name, "Royal Castle")
        XCTAssertTrue(ranked.first?.isConfident ?? false)
    }

    func testVariantsAddTheCityOnce() {
        let list = PlaceFinder.variants(name: "Verso Tower", alternatives: ["Wieża Verso"], city: "Warsaw, Poland")
        XCTAssertEqual(list, ["Verso Tower", "Wieża Verso", "Verso Tower, Warsaw", "Wieża Verso, Warsaw"])
        XCTAssertEqual(PlaceFinder.variants(name: "Warsaw Zoo", alternatives: [], city: "Warsaw"), ["Warsaw Zoo"])
    }

    func testPhotonAnswerBecomesMapItems() {
        let json: [String: Any] = ["features": [[
            "geometry": ["coordinates": [21.0067, 52.2319]],
            "properties": ["name": "Palace of Culture and Science", "street": "Plac Defilad", "housenumber": "1",
                           "city": "Warsaw", "country": "Poland"],
        ], ["geometry": ["coordinates": [1.0, 2.0]], "properties": [:]]]]
        let items = PlaceFinder.parsePhoton(json)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Palace of Culture and Science")
        XCTAssertEqual(items[0].placemark.coordinate.latitude, 52.2319, accuracy: 0.0001)
    }

    func testMergeKeepsASamePlaceOnce() {
        let a = MKMapItem(placemark: MKPlacemark(coordinate: warsaw)); a.name = "Old Town"
        let b = MKMapItem(placemark: MKPlacemark(coordinate: warsaw)); b.name = "Old Town"
        let merged = PlaceFinder.merge(PlaceFinder.rank([a], query: "Old Town", center: warsaw),
                                       PlaceFinder.rank([b], query: "Old Town", center: warsaw))
        XCTAssertEqual(merged.count, 1)
    }
}

final class PlaceWishTests: XCTestCase {
    func testAIAnswerIsParsed() {
        let json: [String: Any] = ["places": [
            ["name": "Palace of Culture and Science", "localName": "Pałac Kultury i Nauki", "kind": "sight",
             "statedTime": "", "bestTime": "21:00", "day": ""],
            ["name": "Verso Tower", "localName": "", "kind": "sight", "statedTime": "21:00", "bestTime": "", "day": "2"],
            ["name": "verso tower", "kind": "sight"],
            ["name": "X"],
        ]]
        let wishes = PlaceWishJSON.parse(json)
        XCTAssertEqual(wishes.count, 2, "duplicates and tiny names are dropped")
        XCTAssertEqual(wishes[0].alternativeNames, ["Pałac Kultury i Nauki"])
        XCTAssertNil(wishes[0].statedMinute)
        XCTAssertEqual(wishes[0].suggestedMinute, 21 * 60)
        XCTAssertEqual(wishes[1].statedMinute, 21 * 60)
        XCTAssertNil(wishes[1].suggestedMinute, "a stated time wins over a suggestion")
        XCTAssertEqual(wishes[1].day, 2)
    }

    func testMinuteParsing() {
        XCTAssertEqual(PlaceWishJSON.minute("18:30"), 1110)
        XCTAssertNil(PlaceWishJSON.minute(""))
        XCTAssertNil(PlaceWishJSON.minute("25:00"))
    }

    func testBestTimeWithoutAnAI() {
        XCTAssertEqual(MustSeeParser.suggestedMinute(forName: "Warsaw Observatory"), 21 * 60)
        XCTAssertEqual(MustSeeParser.suggestedMinute(forName: "Hala Koszyki Market"), 10 * 60)
        XCTAssertNil(MustSeeParser.suggestedMinute(forName: "Republic Square"), "pub inside a word is not a pub")
        XCTAssertNil(MustSeeParser.suggestedMinute(forName: "Royal Castle"))
    }

    func testSuggestedTimeIsLabelled() {
        XCTAssertEqual(MustSee.whenText(minute: 21 * 60, day: nil, suggested: true), "Best around 21:00")
        XCTAssertEqual(MustSee.whenText(minute: 21 * 60, day: 2), "Around 21:00 · Day 2")
    }
}
