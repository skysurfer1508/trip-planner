import Foundation

extension Trip {
    /// Whole days from today until the first day of the trip, or nil once it has started.
    /// Presentational helper for the Overview hero.
    var daysUntilStart: Int? {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: startDate)).day
        guard let days, days > 0 else { return nil }
        return days
    }
}
