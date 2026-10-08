import Foundation

/// Turns minutes after midnight into a date on a given day, the way stop times are shown on the clock.
enum WallClock {
    static func date(on day: Date, minute: Int, calendar: Calendar = .current) -> Date? {
        let clamped = min(max(minute, 0), 23 * 60 + 59)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: day)
    }

    /// Minutes after midnight of a time of day.
    static func minute(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
