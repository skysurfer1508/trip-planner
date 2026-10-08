import Foundation

/// Turns a trip into shareable text or a calendar file.
enum ItineraryExporter {
    static func text(for trip: Trip) -> String {
        var lines = [trip.name]
        if !trip.destination.isEmpty { lines.append(trip.destination) }
        lines.append(Format.dateRange(trip.startDate, trip.endDate))
        lines.append("")

        for (index, day) in trip.sortedDays.enumerated() {
            lines.append("Day \(index + 1) · \(day.date.formatted(date: .complete, time: .omitted))")
            if let hotel = trip.window(for: day.date).anchorName {
                lines.append("   Start from \(hotel)")
            }
            if day.stops.isEmpty {
                lines.append("   (nothing planned)")
            }
            for stop in day.sortedStops {
                var line = "• "
                if let time = stop.plannedTime { line += Format.time(time) + " " }
                line += stop.name
                if !stop.address.isEmpty { line += " (\(stop.address))" }
                lines.append(line)
                if !stop.notes.isEmpty { lines.append("   \(stop.notes)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// An .ics file with the timed stops and the trip's flights and hotel, or nil if there are none.
    @MainActor
    static func icsFile(for trip: Trip) -> URL? {
        CalendarExport.icsFile(for: trip)
    }
}
