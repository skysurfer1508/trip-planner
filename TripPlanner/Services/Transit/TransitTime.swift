import Foundation
import CoreLocation

/// Time zone handling for timetable lookups. Stop times are wall-clock times at the destination, so
/// they have to be turned into real instants before asking a timetable.
enum TransitTime {
    /// Reads the clock face of `wallClock` (as shown in the device's time zone) as a time in `zone`.
    static func instant(wallClock: Date, in zone: TimeZone, deviceCalendar: Calendar = .current) -> Date {
        let parts = deviceCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: wallClock)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: parts) ?? wallClock
    }

    /// Timetables only exist for a limited window ahead. A date further away is replaced by the
    /// next occurrence of the same weekday and time ("typical timetable").
    static func queryInstant(for instant: Date,
                             now: Date = Date(),
                             in zone: TimeZone,
                             horizonDays: Int = 45) -> (instant: Date, isTypical: Bool) {
        guard instant > now.addingTimeInterval(TimeInterval(horizonDays) * 86_400) else { return (instant, false) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: instant)
        let tomorrow = now.addingTimeInterval(86_400)
        guard let next = calendar.nextDate(after: tomorrow, matching: parts, matchingPolicy: .nextTime) else {
            return (instant, false)
        }
        return (next, true)
    }

    /// RFC 3339 in UTC ("2026-06-05T09:00:00Z"), which has no "+" to get lost in a URL.
    static func requestString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func timeText(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(time: .shortened, timeZone: zone))
    }
}
