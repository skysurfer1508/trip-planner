import Foundation
import SwiftData
import CoreLocation
import MapKit

@Model
final class Stop {
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var address: String = ""
    var categoryRaw: String = StopCategory.sight.rawValue
    var plannedTime: Date?
    var durationMinutes: Int = 60
    var notes: String = ""
    var order: Int = 0
    var isDone: Bool = false
    /// Planned cost in the trip's currency, used by the budget.
    var estimatedCost: Double = 0
    var phone: String = ""
    var website: String = ""
    /// Short AI-written tips, cached so they work offline.
    var aiTips: String = ""
    /// Short description (from Wikipedia) and where it came from.
    var summary: String = ""
    var wikiURL: String = ""
    /// Photo of the place: from Wikipedia ("wikipedia") or chosen by the user ("user").
    @Attribute(.externalStorage) var imageData: Data?
    var imageSource: String = ""
    /// When the photo/description lookup last finished; nil means it still has to run.
    var infoCheckedAt: Date?
    var day: Day?

    init(name: String,
         latitude: Double,
         longitude: Double,
         address: String = "",
         category: StopCategory = .sight) {
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

    /// A copy that is not attached to any day yet.
    func clone() -> Stop {
        let copy = Stop(name: name, latitude: latitude, longitude: longitude, address: address, category: category)
        copy.plannedTime = plannedTime
        copy.durationMinutes = durationMinutes
        copy.notes = notes
        copy.estimatedCost = estimatedCost
        copy.phone = phone
        copy.website = website
        copy.aiTips = aiTips
        copy.summary = summary
        copy.wikiURL = wikiURL
        copy.imageData = imageData
        copy.imageSource = imageSource
        copy.infoCheckedAt = infoCheckedAt
        return copy
    }

    /// Builds a stop from an Apple Maps search result. The name and coordinate are copied,
    /// so the trip keeps working offline.
    static func from(_ item: MKMapItem) -> Stop {
        let coordinate = item.placemark.coordinate
        let stop = Stop(name: item.name ?? "Place",
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        address: item.placemark.title ?? "",
                        category: StopCategory(poi: item.pointOfInterestCategory))
        stop.phone = item.phoneNumber ?? ""
        stop.website = item.url?.absoluteString ?? ""
        return stop
    }
}
