import ActivityKit
import Foundation

/// Lock-screen / Dynamic Island countdown to the next stop.
enum LiveActivityManager {
    /// Starts or updates the activity for the next stop, or ends it when nothing is left.
    @MainActor
    static func sync(tripName: String, next: Stop?, stopsLeft: Int) async {
        guard let next else {
            await end()
            return
        }
        let state = TripActivityAttributes.ContentState(stopName: next.name,
                                                        plannedTime: next.plannedTime,
                                                        stopsLeft: stopsLeft)
        let content = ActivityContent(state: state, staleDate: nil)

        if let current = Activity<TripActivityAttributes>.activities.first {
            await current.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: TripActivityAttributes(tripName: tripName),
                                      content: content,
                                      pushType: nil)
        }
    }

    static func end() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
