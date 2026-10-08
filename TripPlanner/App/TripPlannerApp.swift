import SwiftUI
import SwiftData

@main
struct TripPlannerApp: App {
    @State private var location = LocationService()
    @State private var secrets = Secrets()

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        // Edit Scheme > Run > Arguments > add `-designGallery` to open the design-system gallery
        // instead of the trip list. Handy for screenshots in light, dark and large text.
        if ProcessInfo.processInfo.arguments.contains("-designGallery") {
            DesignSystemGallery()
        } else {
            TripListView()
        }
        #else
        TripListView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                .environment(location)
                .environment(secrets)
        }
        .modelContainer(for: [Trip.self, Day.self, Stop.self, Expense.self, ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self])
    }
}
