import SwiftUI

/// Everything about one trip, in tabs. Trip Mode (the live guide) is one tap away in the toolbar.
struct TripHubView: View {
    @Bindable var trip: Trip

    var body: some View {
        TabView {
            PlannerView(trip: trip)
                .tabItem { Label("Plan", systemImage: "list.bullet.rectangle") }
            DiscoverView(trip: trip)
                .tabItem { Label("Discover", systemImage: "sparkles") }
            BudgetView(trip: trip)
                .tabItem { Label("Budget", systemImage: "creditcard") }
            ChecklistView(trip: trip)
                .tabItem { Label("Packing", systemImage: "checklist") }
            DocumentsView(trip: trip)
                .tabItem { Label("Documents", systemImage: "folder") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TodayView(trip: trip)
                } label: {
                    Label("Trip Mode", systemImage: "location.fill")
                }
            }
        }
    }
}
