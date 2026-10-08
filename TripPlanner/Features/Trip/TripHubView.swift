import SwiftUI

enum TripTab: Hashable {
    case overview, plan, discover, budget, more
}

/// Everything about one trip. Overview is the home. Trip Mode (the live guide) is a floating "Today"
/// button while the trip is live, and a card on Overview otherwise.
struct TripHubView: View {
    @Bindable var trip: Trip
    var startAction: TripStartAction?

    @State private var tab: TripTab = .overview
    @State private var handledStart = false
    @State private var showEdit = false
    @State private var showImport = false
    @State private var showAutoPlan = false
    @State private var showDocuments = false
    @State private var showBookings = false
    @State private var showPacking = false

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(trip: trip, perform: perform)
                .todayShortcut(for: trip)
                .tabItem { Label("Overview", systemImage: "house") }
                .tag(TripTab.overview)
            PlannerView(trip: trip)
                .todayShortcut(for: trip)
                .tabItem { Label("Plan", systemImage: "map") }
                .tag(TripTab.plan)
            DiscoverView(trip: trip)
                .todayShortcut(for: trip)
                .tabItem { Label("Discover", systemImage: "safari") }
                .tag(TripTab.discover)
            BudgetView(trip: trip)
                .todayShortcut(for: trip)
                .tabItem { Label("Budget", systemImage: "creditcard") }
                .tag(TripTab.budget)
            MoreView(trip: trip)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(TripTab.more)
        }
        .minimizingTabBar()
        .sheet(isPresented: $showEdit) {
            TripEditView(trip: trip)
        }
        .sheet(isPresented: $showImport) {
            ImportFlowView(trip: trip)
        }
        .sheet(isPresented: $showAutoPlan) {
            AutoPlanFlowView(trip: trip)
        }
        .sheet(isPresented: $showBookings) {
            ToolSheet { BookingsView(trip: trip) }
        }
        .sheet(isPresented: $showDocuments) {
            ToolSheet { DocumentsView(trip: trip) }
        }
        .sheet(isPresented: $showPacking) {
            ToolSheet { ChecklistView(trip: trip) }
        }
        .task {
            // The wizard can ask for a first action; wait for the push animation to finish.
            guard !handledStart, let startAction else { return }
            handledStart = true
            try? await Task.sleep(for: .milliseconds(700))
            switch startAction {
            case .importProgram: showImport = true
            case .autoPlan: showAutoPlan = true
            }
        }
    }

    private func perform(_ action: SetupAction) {
        switch action {
        case .editTrip: showEdit = true
        case .addPlaces: tab = .plan
        case .importProgram: showImport = true
        case .autoPlan: showAutoPlan = true
        case .bookings: showBookings = true
        case .documents: showDocuments = true
        case .packing: showPacking = true
        case .budget: tab = .budget
        }
    }
}

/// Wraps a pushed-style screen so it can be shown as a sheet with a Done button.
struct ToolSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
