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

    /// Stops with a time first (earliest first); the others keep their relative order after them.
    func sortByTime() {
        let indexed = Array(sortedStops.enumerated())
        let sorted = indexed.sorted { a, b in
            switch (a.element.plannedTime, b.element.plannedTime) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        renumber(sorted.map(\.element))
    }

    /// Moves a stop of this day to another day, keeping its time of day.
    func move(_ stop: Stop, to target: Day) {
        guard target.persistentModelID != persistentModelID else { return }
        stops.removeAll { $0 === stop }
        if let time = stop.plannedTime {
            stop.plannedTime = target.combine(time: time)
        }
        target.append(stop)
        renumber(sortedStops)
    }

    /// Adds a copy of `stop` right after it.
    func duplicate(_ stop: Stop) {
        let copy = stop.clone()
        modelContext?.insert(copy)
        stops.append(copy)
        var ordered = sortedStops.filter { $0 !== copy }
        let index = ordered.firstIndex { $0 === stop } ?? (ordered.count - 1)
        ordered.insert(copy, at: min(index + 1, ordered.count))
        renumber(ordered)
    }

    /// Appends copies of all stops of this day to `target`, shifting times to that day.
    func copyStops(to target: Day) {
        guard target.persistentModelID != persistentModelID else { return }
        for stop in sortedStops {
            let copy = stop.clone()
            copy.isDone = false
            if let time = copy.plannedTime {
                copy.plannedTime = target.combine(time: time)
            }
            target.append(copy)
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
