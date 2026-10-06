import Foundation

/// Puts flights and hotel check-in/out on the plan as stops, at the right day and time.
enum BookingPlanner {
    struct Result {
        var added = 0
        var skippedWithoutLocation = 0
    }

    @discardableResult
    static func addStops(for trip: Trip) -> Result {
        var result = Result()
        let calendar = Calendar.current

        func day(for date: Date) -> Day? {
            trip.days.first { calendar.isDate($0.date, inSameDayAs: date) }
        }

        func add(_ name: String, at date: Date, place: Booking, category: StopCategory, minutes: Int,
                 coordinateOverride: (Double, Double)? = nil) {
            guard let day = day(for: date) else { return }
            guard place.hasCoordinate || coordinateOverride != nil else {
                result.skippedWithoutLocation += 1
                return
            }
            if day.stops.contains(where: { $0.name == name }) { return }
            let latitude = coordinateOverride?.0 ?? place.latitude
            let longitude = coordinateOverride?.1 ?? place.longitude
            let stop = Stop(name: name, latitude: latitude, longitude: longitude,
                            address: place.address, category: category)
            stop.durationMinutes = minutes
            stop.plannedTime = date
            day.append(stop)
            result.added += 1
        }

        let hotels = trip.bookings.filter { $0.kind == .hotel && $0.hasCoordinate }

        for booking in trip.bookings {
            switch booking.kind {
            case .arrivalFlight:
                add("Land · \(booking.title.isEmpty ? "flight" : booking.title)", at: booking.endDate,
                    place: booking, category: .transport, minutes: 30)
            case .departureFlight:
                let leave = booking.startDate.addingTimeInterval(-TimeInterval(booking.bufferMinutes * 60))
                // Leaving for the airport starts at the hotel when there is one.
                let flightDay = calendar.startOfDay(for: booking.startDate)
                let hotel = hotels.first(where: { stay in
                    calendar.startOfDay(for: stay.startDate) <= flightDay
                        && flightDay <= calendar.startOfDay(for: stay.endDate)
                })
                add("Leave for the airport", at: leave, place: booking, category: .transport, minutes: 15,
                    coordinateOverride: hotel.map { ($0.latitude, $0.longitude) })
                add("Flight \(booking.title)", at: booking.startDate, place: booking, category: .transport, minutes: 30)
            case .hotel:
                add("Check in · \(booking.title)", at: booking.startDate, place: booking, category: .hotel, minutes: 30)
                add("Check out · \(booking.title)", at: booking.endDate, place: booking, category: .hotel, minutes: 15)
            }
        }

        for day in trip.days where !day.stops.isEmpty {
            day.sortByTime()
        }
        return result
    }
}
