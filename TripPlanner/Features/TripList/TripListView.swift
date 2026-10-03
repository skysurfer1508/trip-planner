import SwiftUI
import SwiftData

struct TripListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate) private var trips: [Trip]

    @State private var showNewTrip = false
    @State private var showSettings = false
    @State private var tripToEdit: Trip?
    @State private var tripToDelete: Trip?

    /// Running and upcoming trips first, finished ones last.
    private var orderedTrips: [Trip] {
        let upcoming = trips.filter { !$0.isPast }
        let past = trips.filter { $0.isPast }.reversed()
        return upcoming + past
    }

    var body: some View {
        NavigationStack {
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
    @State private var hero: URL?

    private var stopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.count }
    }

    private var gradient: LinearGradient {
        let palette: [[Color]] = [
            [.indigo, .blue], [.teal, .green], [.orange, .pink], [.purple, .indigo], [.blue, .teal], [.pink, .orange],
        ]
        let seed = trip.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let colors = palette[seed % palette.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(gradient)
                .overlay {
                    if let hero {
                        AsyncImage(url: hero) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            }
                        }
                    }
                }
                .clipped()

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
        .task(id: trip.destination) {
            let city = trip.destination.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !city.isEmpty else {
                hero = nil
                return
            }
            hero = await WikipediaService.summary(title: city)?.hero
        }
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
