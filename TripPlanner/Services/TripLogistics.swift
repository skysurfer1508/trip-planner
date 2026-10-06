import Foundation
import CoreLocation

/// A plain copy of a booking, so the planning logic needs no database.
struct BookingInfo {
    let kind: BookingKind
    let title: String
    let placeName: String
    let start: Date
    let end: Date
    let bufferMinutes: Int
    let coordinate: CLLocationCoordinate2D?
    let remind: Bool
}

struct LogisticsItem: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
    /// Minutes after midnight.
    let minute: Int
}

/// What a flight and hotel mean for one day: when it can start, when it has to end, where it
/// starts from, and the bookings to show.
struct DayWindow {
    var startMinute: Int?
    var endMinute: Int?
    var anchor: CLLocationCoordinate2D?
    var anchorName: String?
    var items: [LogisticsItem] = []

    var isEmpty: Bool { startMinute == nil && endMinute == nil && anchor == nil && items.isEmpty }
}

enum TripLogistics {
    static func window(for day: Date, bookings: [BookingInfo], calendar: Calendar = .current) -> DayWindow {
        var window = DayWindow()
        let dayStart = calendar.startOfDay(for: day)

        func minute(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        func isThisDay(_ date: Date) -> Bool {
            calendar.isDate(date, inSameDayAs: dayStart)
        }

        for booking in bookings {
            switch booking.kind {
            case .arrivalFlight where isThisDay(booking.end):
                let ready = min(minute(booking.end) + booking.bufferMinutes, 23 * 60 + 59)
                window.startMinute = max(window.startMinute ?? 0, ready)
                window.items.append(LogisticsItem(symbol: "airplane.arrival",
                                                  text: "Land \(booking.title) \(booking.placeName)".trimmingCharacters(in: .whitespaces),
                                                  minute: minute(booking.end)))
            case .departureFlight where isThisDay(booking.start):
                let leave = max(minute(booking.start) - booking.bufferMinutes, 0)
                window.endMinute = min(window.endMinute ?? Int.max, leave)
                window.items.append(LogisticsItem(symbol: "figure.walk.departure",
                                                  text: "Leave for the airport",
                                                  minute: leave))
                window.items.append(LogisticsItem(symbol: "airplane.departure",
                                                  text: "Take-off \(booking.title)".trimmingCharacters(in: .whitespaces),
                                                  minute: minute(booking.start)))
            case .hotel:
                if isThisDay(booking.start) {
                    window.items.append(LogisticsItem(symbol: "key.fill", text: "Check in · \(booking.title)",
                                                      minute: minute(booking.start)))
                }
                if isThisDay(booking.end) {
                    window.items.append(LogisticsItem(symbol: "door.left.hand.open", text: "Check out · \(booking.title)",
                                                      minute: minute(booking.end)))
                }
            default:
                break
            }
        }

        // The hotel you sleep in (or leave that morning) is where the day starts from.
        let staying = bookings
            .filter { booking in
                booking.kind == .hotel
                    && booking.coordinate != nil
                    && calendar.startOfDay(for: booking.start) <= dayStart
                    && dayStart <= calendar.startOfDay(for: booking.end)
            }
            .sorted { $0.start > $1.start }
        if let hotel = staying.first {
            window.anchor = hotel.coordinate
            window.anchorName = hotel.title
        }

        window.items.sort { $0.minute < $1.minute }
        return window
    }

    static func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

extension Trip {
    func window(for date: Date) -> DayWindow {
        TripLogistics.window(for: date, bookings: bookings.map(\.info))
    }

    /// The hotel that covers the given day, if any.
    func hotelCoordinate(on date: Date) -> CLLocationCoordinate2D? {
        window(for: date).anchor
    }
}
