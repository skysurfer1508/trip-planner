import SwiftUI
import MapKit

enum StopCategory: String, CaseIterable, Identifiable, Codable {
    case sight, food, cafe, hotel, transport, nightlife, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sight: "Sight"
        case .food: "Food"
        case .cafe: "Café"
        case .hotel: "Hotel"
        case .transport: "Transport"
        case .nightlife: "Nightlife"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .sight: "camera.fill"
        case .food: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .hotel: "bed.double.fill"
        case .transport: "tram.fill"
        case .nightlife: "moon.stars.fill"
        case .other: "mappin"
        }
    }

    /// Glyph tint on a neutral surface (see `Theme.category`). Never use it as a pin or route fill.
    var color: Color { Theme.category(self) }

    /// Used for the rain warning in the weather chip.
    var isOutdoor: Bool { self == .sight }

    init(poi: MKPointOfInterestCategory?) {
        guard let poi else {
            self = .other
            return
        }
        switch poi {
        case .restaurant, .foodMarket:
            self = .food
        case .brewery, .winery, .nightlife:
            self = .nightlife
        case .cafe, .bakery:
            self = .cafe
        case .hotel:
            self = .hotel
        case .airport, .publicTransport, .parking, .evCharger:
            self = .transport
        case .museum, .park, .beach, .nationalPark, .zoo, .aquarium, .amusementPark, .theater, .stadium:
            self = .sight
        default:
            self = .other
        }
    }
}
