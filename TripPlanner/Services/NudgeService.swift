import Foundation
import CoreLocation
import UserNotifications

/// "Time to leave" notifications for upcoming stops. They assume you walk.
enum NudgeService {
    struct Input {
        let title: String
        let planned: Date
        let coordinate: CLLocationCoordinate2D
    }

    private static let prefix = "nudge-"
    private static let extraBuffer: TimeInterval = 5 * 60
    private static let maxNotifications = 20

    static func requestAuthorization() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Replaces all pending nudges. `inputs` must be in chronological order.
    static func reschedule(_ inputs: [Input], origin: CLLocationCoordinate2D?) async {
        await cancelAll()
        let center = UNUserNotificationCenter.current()
        var previous = origin

        for (index, input) in inputs.prefix(maxNotifications).enumerated() {
            var travel: TimeInterval = 15 * 60
            if let from = previous {
                // One real routing request for the first leg; the rest are estimated.
                if index == 0, let eta = await RoutingService.eta(from: from, to: input.coordinate, mode: .walk) {
                    travel = eta
                } else {
                    travel = RoutingService.estimate(from: from, to: input.coordinate, mode: .walk)
                }
            }
            previous = input.coordinate

            let fire = input.planned.addingTimeInterval(-(travel + extraBuffer))
            let wait = fire.timeIntervalSinceNow
            guard wait > 5 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Time to head out"
            content.body = "\(input.title) starts at \(Format.time(input.planned)). It's about \(Format.duration(travel)) away."
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            let request = UNNotificationRequest(identifier: "\(prefix)\(index)", content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
