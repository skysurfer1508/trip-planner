import ActivityKit
import Foundation

/// Shared between the app and the widget extension.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stopName: String
        var plannedTime: Date?
        var stopsLeft: Int
    }

    var tripName: String
}
