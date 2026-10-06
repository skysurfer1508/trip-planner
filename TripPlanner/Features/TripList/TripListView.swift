import SwiftUI
import SwiftData

struct TripListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate) private var trips: [Trip]

    @State private var showNewTrip = false
    @State private var showSettings = false
    @State private var tripToEdit: Trip?
    @State private var tripToDelete: Trip?
    @State private var path: [Trip] = []
    @State private var openMessage: String?
    @State private var startActions: [PersistentIdentifier: TripStartAction] = [:]

    /// Running and upcoming trips first, finished ones last.
    private var orderedTrips: [Trip] {
        let upcoming = trips.filter { !$0.isPast }
        let past = trips.filter { $0.isPast }.reversed()
        return upcoming + past
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(orderedTrips) { trip in
                        ZStack(alignment: .topTrailing) {
                            NavigationLink(value: trip) {
                                TripCard(trip: trip)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button("Edit", systemImage: "pencil") { tripToEdit = trip }
                                Button("Delete", systemImage: "trash", role: .destructive) { tripToDelete = trip }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(.black.opacity(0.35), in: Circle())
                                    .padding(10)
                            }
                            .accessibilityLabel("Options for \(trip.name)")
                        }
                    }
                }
                .padding()
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
                TripHubView(trip: trip, startAction: startActions[trip.persistentModelID])
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
            .onOpenURL { url in
                do {
                    let added = try TripArchiver.importFile(at: url, into: context)
                    openMessage = added.count == 1
                        ? "Added the trip \"\(added[0].name)\"."
                        : "Added \(added.count) trips."
                } catch {
                    openMessage = error.localizedDescription
                }
            }
            .alert("Trip file",
                   isPresented: Binding(get: { openMessage != nil }, set: { if !$0 { openMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(openMessage ?? "")
            }
            .sheet(isPresented: $showNewTrip) {
                NewTripWizard { trip, action in
                    if let action {
                        startActions[trip.persistentModelID] = action
                    }
                    path.append(trip)
                }
            }
            .sheet(item: $tripToEdit) { trip in
                TripEditView(trip: trip)
            }
            .confirmationDialog("Delete this trip?",
                                isPresented: Binding(get: { tripToDelete != nil },
                                                     set: { if !$0 { tripToDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: tripToDelete) { trip in
                Button("Delete \"\(trip.name)\"", role: .destructive) {
                    context.delete(trip)
                    tripToDelete = nil
                }
            } message: { _ in
                Text("Its days, stops, budget, packing list and documents will be removed.")
            }
        }
    }
}

private struct TripCard: View {
    let trip: Trip

    private var stopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.count }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TripHeroImage(trip: trip)

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                StatusPill(trip: trip)
                Spacer(minLength: 0)
                Text(trip.name)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !trip.destination.isEmpty {
                    Label(trip.destination, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Text("\(Format.dateRange(trip.startDate, trip.endDate)) · \(stopCount) \(stopCount == 1 ? "stop" : "stops")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

private struct StatusPill: View {
    let trip: Trip

    var body: some View {
        Text(trip.isActiveToday ? "LIVE" : trip.statusText)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(trip.isActiveToday ? Color.green : Color.black.opacity(0.4), in: Capsule())
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
