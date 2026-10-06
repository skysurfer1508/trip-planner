import Foundation

struct ScheduleItem: Equatable {
    var planned: Date?
    var durationMinutes: Int
}

struct ScheduleProposal: Equatable {
    let index: Int
    let newTime: Date
}

/// Pure re-flow logic with no SwiftData or UI, so it can be unit tested.
enum ScheduleService {
    /// Minutes between the end of one stop and the start of the next.
    static let bufferMinutes = 10

    /// How far behind schedule the user is, based on the first remaining stop that has a planned
    /// time. Nil when on time.
    static func lateness(items: [ScheduleItem], now: Date) -> TimeInterval? {
        guard let planned = items.compactMap(\.planned).first else { return nil }
        let late = now.timeIntervalSince(planned)
        return late > 0 ? late : nil
    }

    /// Pushes stops that no longer fit back so nothing overlaps. `items` are the remaining
    /// (not done) stops in order. Stops without a planned time are left alone but still take time.
    static func reflow(items: [ScheduleItem], now: Date) -> [ScheduleProposal] {
        var proposals: [ScheduleProposal] = []
        var cursor = roundUp(now)

        for (index, item) in items.enumerated() {
            let block = TimeInterval((item.durationMinutes + bufferMinutes) * 60)
            guard let planned = item.planned else {
                cursor = cursor.addingTimeInterval(block)
                continue
            }
            if planned >= cursor {
                cursor = planned.addingTimeInterval(block)
            } else {
                proposals.append(ScheduleProposal(index: index, newTime: cursor))
                cursor = cursor.addingTimeInterval(block)
            }
        }
        return proposals
    }

    struct AutoItem: Equatable {
        var durationMinutes: Int
        /// Travel time from the previous stop in minutes (ignored for the first stop).
        var travelMinutes: Int
    }

    /// Lays stops out one after another from `start`: stay length, then travel time plus a little slack.
    /// Times are rounded up to 5 minutes. Returns one start time per item.
    static func autoSchedule(items: [AutoItem], start: Date, slackMinutes: Int = 5) -> [Date] {
        var times: [Date] = []
        var cursor = roundUp(start)
        for (index, item) in items.enumerated() {
            if index > 0 {
                cursor = roundUp(cursor.addingTimeInterval(TimeInterval((item.travelMinutes + slackMinutes) * 60)))
            }
            times.append(cursor)
            cursor = cursor.addingTimeInterval(TimeInterval(max(item.durationMinutes, 5) * 60))
        }
        return times
    }

    /// Rounds up to the next 5 minutes.
    static func roundUp(_ date: Date, minutes: Int = 5) -> Date {
        let step = TimeInterval(minutes * 60)
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / step).rounded(.up) * step)
    }
}
