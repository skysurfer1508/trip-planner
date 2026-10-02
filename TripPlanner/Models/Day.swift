import Foundation
import SwiftData

@Model
final class Day {
    var date: Date = Date()
    var notes: String = ""
    @Relationship(deleteRule: .cascade, inverse: \Stop.day) var stops: [Stop] = []
    var trip: Trip?

    init(date: Date) {
        self.date = date
    }

    var sortedStops: [Stop] {
        stops.sorted { $0.order < $1.order }
    }

    /// Appends a stop at the end of the day.
    func append(_ stop: Stop) {
        stop.order = (stops.map(\.order).max() ?? -1) + 1
        modelContext?.insert(stop)
        stops.append(stop)
    }

    /// Rewrites `order` so it matches the given array.
    func renumber(_ ordered: [Stop]) {
        for (index, stop) in ordered.enumerated() {
            stop.order = index
        }
    }

    /// Returns this day's date with the hour and minute of `time`.
    func combine(time: Date) -> Date {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: hm.hour ?? 9,
                             minute: hm.minute ?? 0,
                             second: 0,
                             of: date) ?? time
    }
}
