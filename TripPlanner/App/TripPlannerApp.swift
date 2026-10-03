import SwiftUI
import SwiftData

@main
struct TripPlannerApp: App {
    @State private var location = LocationService()
    @State private var secrets = Secrets()

    var body: some Scene {
        WindowGroup {
            TripListView()
                .environment(location)
                .environment(secrets)
        }
        .modelContainer(for: [Trip.self, Day.self, Stop.self, Expense.self, ChecklistItem.self, TripDocument.self])
    }
}
