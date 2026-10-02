import SwiftUI
import SwiftData

@main
struct TripPlannerApp: App {
    @State private var location = LocationService()

    var body: some Scene {
        WindowGroup {
            TripListView()
                .environment(location)
        }
        .modelContainer(for: [Trip.self, Day.self, Stop.self])
    }
}
