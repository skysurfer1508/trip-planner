import Foundation
import CoreLocation
import CryptoKit
import EventKit

/// One thing to put in a calendar: a stop with a time, or a flight and hotel item of the trip.
struct CalendarEvent: Equatable {
    /// Same text for the same event every time, so a re-import updates instead of duplicating.
    var key: String
    var title: String
    var start: Date
    var end: Date
    var location: String = ""
    var latitude: Double?
    var longitude: Double?
    var notes: String = ""
    var url: String = ""
    var alarmMinutes: Int?
}

enum CalendarExport {
    // MARK: .ics text (pure)

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 bytes continue on the next line, which starts with a space.
    static func fold(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = result.isEmpty ? 75 : 74          // the leading space counts
            if bytes + size > limit {
                result.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        result.append(current)
        return result.enumerated().map { $0.offset == 0 ? $0.element : " " + $0.element }
    }

    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func uid(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(digest)@tripplanner"
    }

    static func ics(events: [CalendarEvent], calendarName: String, now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TripPlanner//EN", "CALSCALE:GREGORIAN",
                     "X-WR-CALNAME:\(escape(calendarName))"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(uid(for: event.key))")
            lines.append("DTSTAMP:\(utc(now))")
            lines.append("DTSTART:\(utc(event.start))")
            lines.append("DTEND:\(utc(event.end))")
            lines.append("SUMMARY:\(escape(event.title))")
            if !event.location.isEmpty { lines.append("LOCATION:\(escape(event.location))") }
            if let latitude = event.latitude, let longitude = event.longitude {
                lines.append("GEO:\(latitude);\(longitude)")
            }
            if !event.notes.isEmpty { lines.append("DESCRIPTION:\(escape(event.notes))") }
            if !event.url.isEmpty { lines.append("URL:\(event.url)") }
            if let minutes = event.alarmMinutes {
                lines.append("BEGIN:VALARM")
                lines.append("TRIGGER:-PT\(minutes)M")
                lines.append("ACTION:DISPLAY")
                lines.append("DESCRIPTION:\(escape(event.title))")
                lines.append("END:VALARM")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.flatMap(fold).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: From a trip

    /// Stops with a time, and the trip's flights and hotel. Times are the clock at the destination, turned
    /// into real moments, so the calendar shows them right wherever the phone is.
    @MainActor
    static func events(for trip: Trip) -> [CalendarEvent] {
        let zone = trip.timeZone
        var result: [CalendarEvent] = []

        for (dayIndex, day) in trip.sortedDays.enumerated() {
            for stop in day.sortedStops {
                guard let planned = stop.plannedTime else { continue }
                let start = TransitTime.instant(wallClock: planned, in: zone)
                let end = start.addingTimeInterval(TimeInterval(max(stop.durationMinutes, 15) * 60))
                var notes: [String] = []
                if !stop.notes.isEmpty { notes.append(stop.notes) }
                if !stop.summary.isEmpty { notes.append(stop.summary) }
                result.append(CalendarEvent(key: "\(trip.name)|\(dayIndex)|\(stop.name)|\(Int(start.timeIntervalSince1970))",
                                            title: stop.name,
                                            start: start,
                                            end: end,
                                            location: stop.address.isEmpty ? stop.name : stop.address,
                                            latitude: stop.latitude,
                                            longitude: stop.longitude,
                                            notes: notes.joined(separator: "\n\n"),
                                            url: stop.website,
                                            alarmMinutes: 30))
            }
            for item in trip.window(for: day.date).items {
                guard let wall = WallClock.date(on: day.date, minute: item.minute) else { continue }
                let start = TransitTime.instant(wallClock: wall, in: zone)
                result.append(CalendarEvent(key: "\(trip.name)|logistics|\(dayIndex)|\(item.text)",
                                            title: item.text,
                                            start: start,
                                            end: start.addingTimeInterval(30 * 60),
                                            alarmMinutes: 60))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// A temporary .ics file to share, or nil when there is nothing to export.
    @MainActor
    static func icsFile(for trip: Trip) -> URL? {
        let events = events(for: trip)
        guard !events.isEmpty else { return nil }
        let safeName = trip.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "trip" : safeName)
            .appendingPathExtension("ics")
        do {
            try ics(events: events, calendarName: trip.name).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Straight into the Calendar app

    enum Failure: LocalizedError {
        case denied
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .denied: "Calendar access was not allowed. You can turn it on in Settings → Trip Planner."
            case .noCalendar: "No calendar is available to add events to."
            }
        }
    }

    /// Adds every event to the default calendar. Only write access is asked for: the app never reads the
    /// calendar. Adding twice adds twice.
    @MainActor
    static func addToCalendar(trip: Trip) async throws -> Int {
        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else { throw Failure.denied }
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure.noCalendar }
        let zone = trip.timeZone
        let list = events(for: trip)
        for event in list {
            let item = EKEvent(eventStore: store)
            item.calendar = calendar
            item.title = event.title
            item.startDate = event.start
            item.endDate = event.end
            item.timeZone = zone
            item.notes = event.notes.isEmpty ? nil : event.notes
            item.url = URL(string: event.url)
            if !event.location.isEmpty {
                let place = EKStructuredLocation(title: event.location)
                if let latitude = event.latitude, let longitude = event.longitude {
                    place.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
                }
                item.structuredLocation = place
            }
            if let minutes = event.alarmMinutes {
                item.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes * 60)))
            }
            try store.save(item, span: .thisEvent, commit: false)
        }
        try store.commit()
        return list.count
    }
}
