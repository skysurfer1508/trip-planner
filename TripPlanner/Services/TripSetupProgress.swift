import Foundation

enum SetupAction {
    case editTrip, addPlaces, importProgram, autoPlan, documents, packing, budget, bookings
}

struct SetupStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isDone: Bool
    let action: SetupAction
    let actionTitle: String
}

/// What is still missing before the trip is ready, derived from the trip's data.
enum TripSetupProgress {
    static func steps(for trip: Trip) -> [SetupStep] {
        let stopCount = trip.days.reduce(0) { $0 + $1.stops.count }
        let hasBooking = trip.documents.contains { $0.kind == .ticket || $0.kind == .booking }

        return [
            SetupStep(id: "destination",
                      title: "Pick the destination",
                      detail: "Unlocks suggestions, weather and better search.",
                      isDone: trip.hasDestinationCoordinate,
                      action: .editTrip,
                      actionTitle: "Set"),
            SetupStep(id: "logistics",
                      title: "Add flights and hotel",
                      detail: "So plans respect when you arrive and when you must leave.",
                      isDone: trip.bookings.contains { $0.kind == .hotel }
                          && trip.bookings.contains { $0.kind != .hotel },
                      action: .bookings,
                      actionTitle: "Add"),
            SetupStep(id: "stops",
                      title: "Plan some stops",
                      detail: "Add places, import your program or let Auto plan build it.",
                      isDone: stopCount >= 3,
                      action: .addPlaces,
                      actionTitle: "Add"),
            SetupStep(id: "bookings",
                      title: "Save tickets and bookings",
                      detail: "Keep them offline in Documents.",
                      isDone: hasBooking,
                      action: .documents,
                      actionTitle: "Open"),
            SetupStep(id: "budget",
                      title: "Set a budget",
                      detail: "Track what you spend against it.",
                      isDone: trip.budget > 0,
                      action: .budget,
                      actionTitle: "Set"),
            SetupStep(id: "packing",
                      title: "Start a packing list",
                      detail: "A suggested list based on the forecast.",
                      isDone: !trip.checklist.isEmpty,
                      action: .packing,
                      actionTitle: "Start"),
        ]
    }

    static func completed(for trip: Trip) -> Int {
        steps(for: trip).filter(\.isDone).count
    }
}
