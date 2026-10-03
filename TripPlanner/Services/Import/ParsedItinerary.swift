import Foundation

struct ParsedStop: Identifiable {
    let id = UUID()
    var title: String
    var hour: Int?
    var minute: Int?
    var notes = ""
    var category: StopCategory = .other
    /// 0...1: how sure the parser is that this line is a place to visit.
    var confidence: Double = 1
}

struct ParsedDay: Identifiable {
    let id = UUID()
    var label: String?
    var date: Date?
    var stops: [ParsedStop] = []
}

struct ParsedItinerary {
    var days: [ParsedDay]

    var stopCount: Int { days.reduce(0) { $0 + $1.stops.count } }
}
