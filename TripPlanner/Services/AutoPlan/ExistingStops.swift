import Foundation

/// The stops already in a trip, turned into fixed points for Auto plan to build around.
enum ExistingStops {
    private static let logisticsPrefixes = ["Land ·", "Check in", "Check out", "Leave for the airport", "Flight "]

    /// Arrivals, departures and hotel check-ins come from the bookings and stay as they are.
    static func isLogistics(_ stop: Stop) -> Bool {
        if stop.category == .hotel || stop.category == .transport { return true }
        return logisticsPrefixes.contains { stop.name.hasPrefix($0) }
    }

    static func kind(for category: StopCategory) -> DiscoverKind {
        switch category {
        case .food: .food
        case .cafe: .cafe
        case .nightlife: .nightlife
        default: .sights
        }
    }

    struct Collected {
        var candidates: [PlanCandidate] = []
        /// The stop behind each candidate (by `existingKey`), to copy its notes, photo and cost.
        var stops: [String: Stop] = [:]
    }

    /// Stops of the first `dayCount` days, with the day and time they have now.
    static func collect(trip: Trip, dayCount: Int, calendar: Calendar = .current) -> Collected {
        var result = Collected()
        for (dayIndex, day) in trip.sortedDays.prefix(dayCount).enumerated() {
            for (position, stop) in day.sortedStops.enumerated() where !isLogistics(stop) {
                let key = "existing-\(dayIndex)-\(position)"
                var candidate = PlanCandidate(id: key,
                                              name: stop.name,
                                              coordinate: stop.coordinate,
                                              kind: kind(for: stop.category),
                                              score: 1,
                                              address: stop.address,
                                              isMustSee: true)
                candidate.preferredDay = dayIndex + 1
                if let time = stop.plannedTime {
                    let parts = calendar.dateComponents([.hour, .minute], from: time)
                    candidate.preferredMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
                candidate.fixedDuration = stop.durationMinutes
                candidate.existingKey = key
                result.candidates.append(candidate)
                result.stops[key] = stop
            }
        }
        return result
    }
}
