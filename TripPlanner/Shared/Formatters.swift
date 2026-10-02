import Foundation
import CoreLocation

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func minutes(_ minutes: Int) -> String {
        duration(TimeInterval(minutes * 60))
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int((meters / 10).rounded()) * 10) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayChip(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}
