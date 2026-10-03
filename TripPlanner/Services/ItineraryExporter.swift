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

    /// An .ics file with one event per stop that has a planned time, or nil if there are none.
    /// Times are "floating", so they show as local time wherever the calendar is opened.
    static func icsFile(for trip: Trip) -> URL? {
        let local = DateFormatter()
        local.calendar = Calendar(identifier: .gregorian)
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyyMMdd'T'HHmmss"

        let utc = DateFormatter()
        utc.calendar = Calendar(identifier: .gregorian)
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TripPlanner//EN", "CALSCALE:GREGORIAN"]
        var events = 0
        let stamp = utc.string(from: Date())

        for day in trip.sortedDays {
            for stop in day.sortedStops {
                guard let start = stop.plannedTime else { continue }
                let end = start.addingTimeInterval(TimeInterval(max(stop.durationMinutes, 15) * 60))
                lines.append("BEGIN:VEVENT")
                lines.append("UID:\(UUID().uuidString)@tripplanner")
                lines.append("DTSTAMP:\(stamp)")
                lines.append("DTSTART:\(local.string(from: start))")
                lines.append("DTEND:\(local.string(from: end))")
                lines.append("SUMMARY:\(escape(stop.name))")
                if !stop.address.isEmpty { lines.append("LOCATION:\(escape(stop.address))") }
                lines.append("GEO:\(stop.latitude);\(stop.longitude)")
                if !stop.notes.isEmpty { lines.append("DESCRIPTION:\(escape(stop.notes))") }
                lines.append("END:VEVENT")
                events += 1
            }
        }
        lines.append("END:VCALENDAR")
        guard events > 0 else { return nil }

        let safeName = trip.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "trip" : safeName)
            .appendingPathExtension("ics")
        do {
            try lines.joined(separator: "\r\n").appending("\r\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
