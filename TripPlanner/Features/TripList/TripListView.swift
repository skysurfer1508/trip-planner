import SwiftUI
import SwiftData

struct TripListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate) private var trips: [Trip]

    @State private var showNewTrip = false
    @State private var showSettings = false
    @State private var tripToEdit: Trip?

    var body: some View {
        NavigationStack {
            List {
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        TripRow(trip: trip)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { tripToEdit = trip }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Edit", systemImage: "pencil") { tripToEdit = trip }
                            .tint(.blue)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        context.delete(trips[index])
                    }
                }
            }
            .overlay {
                if trips.isEmpty {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "airplane")
                    } description: {
                        Text("Create your first trip to start planning.")
                    } actions: {
                        Button("New trip") { showNewTrip = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Trips")
            .navigationDestination(for: Trip.self) { trip in
                TripHubView(trip: trip)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New trip", systemImage: "plus") { showNewTrip = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showNewTrip) {
                TripEditView(trip: nil)
            }
            .sheet(item: $tripToEdit) { trip in
                TripEditView(trip: trip)
            }
        }
    }
}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.name)
                    .font(.headline)
                if trip.isActiveToday {
                    Text("LIVE")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            if !trip.destination.isEmpty {
                Label(trip.destination, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(Format.dateRange(trip.startDate, trip.endDate)) · \(trip.statusText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    TripListView()
        .environment(LocationService())
        .environment(Secrets())
        .modelContainer(SampleData.container)
}
#endif
