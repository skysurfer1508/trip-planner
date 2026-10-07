import Foundation
import SwiftData
import CoreLocation

enum BookingKind: String, CaseIterable, Identifiable {
    case arrivalFlight, departureFlight, hotel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrivalFlight: "Flight to the destination"
        case .departureFlight: "Flight home"
        case .hotel: "Hotel"
        }
    }

    var shortTitle: String {
        switch self {
        case .arrivalFlight: "Arrival"
        case .departureFlight: "Departure"
        case .hotel: "Hotel"
        }
    }

    var symbol: String {
        switch self {
        case .arrivalFlight: "airplane.arrival"
        case .departureFlight: "airplane.departure"
        case .hotel: "bed.double.fill"
        }
    }
}

/// A flight or hotel stay. Times are entered as printed on the ticket or booking (local time).
@Model
final class Booking {
    var kindRaw: String = BookingKind.hotel.rawValue
    /// Flight number, or the hotel's name.
    var title: String = ""
    /// Hotel check-in, or flight take-off.
    var startDate: Date = Date()
    /// Hotel check-out, or flight landing.
    var endDate: Date = Date()
    /// The airport or hotel as found on the map.
    var placeName: String = ""
    /// Where a flight comes from or goes to.
    var otherEnd: String = ""
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var hasCoordinate: Bool = false
    var reference: String = ""
    var notes: String = ""
    /// Arrival: time to get out of the airport and to the hotel. Departure: time needed before
    /// take-off (travel to the airport, check-in, security).
    var bufferMinutes: Int = 120
    var remind: Bool = true
    /// Hotel contact details from the map, for quick access during the trip.
    var phone: String = ""
    var website: String = ""
    var trip: Trip?

    init(kind: BookingKind, title: String = "", startDate: Date, endDate: Date) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        switch kind {
        case .arrivalFlight: bufferMinutes = 120
        case .departureFlight: bufferMinutes = 180
        case .hotel: bufferMinutes = 0
        }
    }

    var kind: BookingKind {
        get { BookingKind(rawValue: kindRaw) ?? .hotel }
        set { kindRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D? {
        hasCoordinate ? CLLocationCoordinate2D(latitude: latitude, longitude: longitude) : nil
    }

    /// The moment that matters for planning: landing, take-off or check-in.
    var keyDate: Date {
        switch kind {
        case .arrivalFlight: endDate
        case .departureFlight, .hotel: startDate
        }
    }

    var info: BookingInfo {
        BookingInfo(kind: kind, title: title, placeName: placeName, start: startDate, end: endDate,
                    bufferMinutes: bufferMinutes, coordinate: coordinate, remind: remind)
    }
}
