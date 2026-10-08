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

    /// Running trips first, then upcoming ones by start date.
    private var upcoming: [Trip] { trips.filter { !$0.isPast } }
    /// Finished trips, most recent first.
    private var past: [Trip] { Array(trips.filter { $0.isPast }.reversed()) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    if let featured = upcoming.first {
                        tripLink(featured, style: .featured)
                    }
                    if upcoming.count > 1 {
                        SectionHeader(title: "Upcoming")
                            .padding(.top, Spacing.s)
                        ForEach(Array(upcoming.dropFirst())) { trip in
                            tripLink(trip, style: .regular)
                        }
                    }
                    if !past.isEmpty {
                        SectionHeader(title: "Past")
                            .padding(.top, Spacing.s)
                        ForEach(past) { trip in
                            tripLink(trip, style: .compact)
                        }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .background(Theme.background)
            .overlay {
                if trips.isEmpty {
                    EmptyState(title: "No trips yet", systemImage: "airplane",
                               message: "Create your first trip to start planning.",
                               actionTitle: "New trip") { showNewTrip = true }
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
                    Haptics.warning()
                    context.delete(trip)
                    tripToDelete = nil
                }
            } message: { _ in
                Text("Its days, stops, budget, packing list and documents will be removed.")
            }
        }
    }
}

private extension TripListView {
    /// A trip card with its options menu on top. The menu has a 44 pt target.
    func tripLink(_ trip: Trip, style: TripCard.Style) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: trip) {
                TripCard(trip: trip, style: style)
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
                    .background(.black.opacity(0.45), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(Spacing.xs)
            .accessibilityLabel("Options for \(trip.name)")
        }
    }
}

/// Photo first. White text sits on a dark scrim that is strongest at the bottom, so it stays readable
/// over bright photos (the darkest-needed case is a white photo: scrim 0.8 black gives about 12:1).
private struct TripCard: View {
    enum Style {
        /// The running or next trip: big and raised.
        case featured
        case regular
        /// Finished trips.
        case compact

        var height: CGFloat {
            switch self {
            case .featured: 320
            case .regular: 210
            case .compact: 150
            }
        }
    }

    let trip: Trip
    let style: Style

    @ScaledMetric(relativeTo: .title2) private var scale: CGFloat = 1

    private var stopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.count }
    }

    private var radius: CGFloat { style == .featured ? Radius.hero : Radius.card }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TripStatusPill(trip: trip)
            Spacer(minLength: Spacing.xl)
            Text(trip.name)
                .font(style == .featured ? Typography.display : Typography.title)
                .foregroundStyle(.white)
                .lineLimit(3)
            if !trip.destination.isEmpty {
                Label(trip.destination, systemImage: "mappin.and.ellipse")
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
            }
            Text("\(Format.dateRange(trip.startDate, trip.endDate)) · \(stopCount) \(stopCount == 1 ? "stop" : "stops")")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, minHeight: style.height * min(scale, 1.5), alignment: .bottomLeading)
        .background {
            ZStack {
                TripHeroImage(trip: trip)
                LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                       .init(color: .black.opacity(0.35), location: 0.6),
                                       .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(Radius.shape(radius))
        .elevation(style == .featured ? .raised : .none)
        .contentShape(Radius.shape(radius))
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
