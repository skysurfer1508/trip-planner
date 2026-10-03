import Foundation
import SwiftData
import CoreLocation

/// A place bookmarked for the trip but not yet scheduled on a day (the "wishlist").
@Model
final class SavedPlace {
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var address: String = ""
    var categoryRaw: String = StopCategory.sight.rawValue
    var savedAt: Date = Date()
    var trip: Trip?

    init(name: String, latitude: Double, longitude: Double, address: String = "", category: StopCategory = .sight) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.categoryRaw = category.rawValue
    }

    var category: StopCategory {
        get { StopCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
