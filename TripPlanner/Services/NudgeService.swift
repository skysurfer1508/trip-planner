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

    private static let liveID = "nudge-live"

    /// One reminder for the connection being watched; a new one replaces the old.
    static func scheduleLive(at date: Date, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [liveID])
        let wait = date.timeIntervalSinceNow
        guard wait > 20 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: liveID,
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
        try? await center.add(request)
    }

    static func cancelLive() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [liveID])
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

// MARK: - Flight and hotel reminders

extension NudgeService {
    private static let bookingPrefix = "booking-"

    /// Replaces all flight/hotel reminders: a heads-up the evening before a flight, "time to leave
    /// for the airport", and a check-out reminder. Only bookings with "Remind me" on are used.
    static func rescheduleBookingReminders(_ bookings: [BookingInfo]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(bookingPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        var requests: [(id: String, date: Date, title: String, body: String)] = []
        let calendar = Calendar.current

        for (index, booking) in bookings.enumerated() where booking.remind {
            switch booking.kind {
            case .departureFlight:
                let leave = booking.start.addingTimeInterval(-TimeInterval(booking.bufferMinutes * 60))
                requests.append(("\(bookingPrefix)leave-\(index)", leave,
                                 "Time to leave for the airport",
                                 "\(booking.title) takes off at \(Format.time(booking.start))."))
                let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: booking.start))
                if let evening = dayBefore.flatMap({ calendar.date(bySettingHour: 20, minute: 0, second: 0, of: $0) }) {
                    requests.append(("\(bookingPrefix)eve-\(index)", evening,
                                     "Flight tomorrow",
                                     "\(booking.title) takes off at \(Format.time(booking.start)). Leave by \(Format.time(leave))."))
                }
            case .hotel:
                let checkout = booking.end.addingTimeInterval(-60 * 60)
                requests.append(("\(bookingPrefix)out-\(index)", checkout,
                                 "Check-out soon",
                                 "Check out of \(booking.title) by \(Format.time(booking.end))."))
            case .arrivalFlight:
                break
            }
        }

        for request in requests.prefix(30) {
            let wait = request.date.timeIntervalSinceNow
            guard wait > 5 else { continue }
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
        }
    }
}
