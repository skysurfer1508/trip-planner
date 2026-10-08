import SwiftUI

/// Home of a trip: where things stand, what's next, and what is still missing.
struct OverviewView: View {
    @Bindable var trip: Trip
    var perform: (SetupAction) -> Void

    private var stopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.count }
    }

    private var dayCount: Int { trip.days.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero

                if trip.isActiveToday {
                    todayCard
                } else if !trip.isPast {
                    upcomingCard
                }

                logisticsCard

                if trip.transport == .transit {
                    TransitGuideCard(trip: trip)
                }

                if stopCount > 0 {
                    OfflinePackCard(trip: trip)
                }

                if !trip.destination.isEmpty {
                    PracticalInfoCard(trip: trip)
                }

                WeatherChip(date: trip.isActiveToday ? Date() : trip.startDate,
                            coordinate: trip.anyCoordinate)

                statsRow
                setupCard
                quickActions
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pieces

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            TripHeroImage(trip: trip)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.statusText.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.9))
                Text(trip.name)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                if !trip.destination.isEmpty {
                    Label(trip.destination, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(Format.dateRange(trip.startDate, trip.endDate))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var todayCard: some View {
        let day = trip.todayDay
        let remaining = day?.sortedStops.filter { !$0.isDone } ?? []

        VStack(alignment: .leading, spacing: 10) {
            Text("TODAY")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if let next = remaining.first {
                Text(next.name)
                    .font(.title3.bold())
                HStack(spacing: 10) {
                    if let time = next.plannedTime {
                        Label(Format.time(time), systemImage: "clock")
                    }
                    Label("\(remaining.count) left", systemImage: "list.bullet")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if day?.stops.isEmpty ?? true {
                Text("Nothing planned for today yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("All done for today", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            NavigationLink {
                TodayView(trip: trip)
            } label: {
                Label("Open Trip Mode", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .card()
    }

    @ViewBuilder
    private var upcomingCard: some View {
        let first = trip.sortedDays.first
        VStack(alignment: .leading, spacing: 6) {
            Text(trip.statusText.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if let first, !first.stops.isEmpty {
                Text("First day: \(first.stops.count) \(first.stops.count == 1 ? "stop" : "stops") planned")
                    .font(.subheadline)
                if let name = first.sortedStops.first?.name {
                    Text("Starting at \(name)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing planned for the first day yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    /// Arrival, hotel and departure at a glance, with how long until the next one.
    @ViewBuilder
    private var logisticsCard: some View {
        let upcoming = trip.bookings
            .filter { $0.keyDate > Date().addingTimeInterval(-6 * 3600) }
            .sorted { $0.keyDate < $1.keyDate }

        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("FLIGHTS & HOTEL")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage") { perform(.bookings) }
                        .font(.caption.bold())
                }
                ForEach(upcoming.prefix(4)) { booking in
                    HStack(spacing: 12) {
                        Image(systemName: booking.kind.symbol)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline(for: booking))
                                .font(.subheadline.bold())
                            Text(subline(for: booking))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card()
        }
    }

    private func headline(for booking: Booking) -> String {
        let name = booking.title.isEmpty ? booking.kind.shortTitle : booking.title
        switch booking.kind {
        case .arrivalFlight: return "Land \(name) · \(booking.endDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
        case .departureFlight: return "\(name) takes off · \(booking.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
        case .hotel: return "\(name) · check-in \(booking.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
        }
    }

    private func subline(for booking: Booking) -> String {
        switch booking.kind {
        case .arrivalFlight:
            let ready = booking.endDate.addingTimeInterval(TimeInterval(booking.bufferMinutes * 60))
            return "Day 1 can start around \(Format.time(ready))"
        case .departureFlight:
            let leave = booking.startDate.addingTimeInterval(-TimeInterval(booking.bufferMinutes * 60))
            return "Leave for the airport by \(Format.time(leave))"
        case .hotel:
            return "Check-out \(booking.endDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("\(dayCount)", dayCount == 1 ? "day" : "days", "calendar")
            stat("\(stopCount)", stopCount == 1 ? "stop" : "stops", "mappin.and.ellipse")
            stat(trip.budget > 0 ? trip.budget.formatted(.currency(code: trip.currencyCode).precision(.fractionLength(0))) : "–",
                 "budget", "creditcard")
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var setupCard: some View {
        let steps = TripSetupProgress.steps(for: trip)
        let done = steps.filter(\.isDone).count

        if done < steps.count {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Get ready")
                        .font(.headline)
                    Spacer()
                    Text("\(done)/\(steps.count)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(done), total: Double(steps.count))

                ForEach(steps) { step in
                    HStack(spacing: 12) {
                        Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(step.isDone ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .strikethrough(step.isDone)
                                .foregroundStyle(step.isDone ? .secondary : .primary)
                            if !step.isDone {
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !step.isDone {
                            Button(step.actionTitle) { perform(step.action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .card()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction("Add place", "plus.circle.fill", .addPlaces)
            quickAction("Import", "doc.viewfinder", .importProgram)
            quickAction("Auto plan", "wand.and.stars", .autoPlan)
        }
    }

    private func quickAction(_ title: String, _ symbol: String, _ action: SetupAction) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
