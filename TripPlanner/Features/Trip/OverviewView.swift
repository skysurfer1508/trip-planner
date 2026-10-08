import SwiftUI

/// Home of a trip. Three visual weights, top to bottom:
/// 1. the hero (photo, title, countdown),
/// 2. ONE raised card: what is happening today, or what comes first,
/// 3. everything else, flat: flights and hotel, tools, the setup checklist, and trip facts.
struct OverviewView: View {
    @Bindable var trip: Trip
    var perform: (SetupAction) -> Void

    @State private var showSetup = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var heroScale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 260

    private var stopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.count }
    }

    private var dayCount: Int { trip.days.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                hero
                primaryCard
                bookingsStrip
                toolsGrid
                setupSection
                goodToKnow
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xxl)
        }
        .background(Theme.background)
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top) {
                TripStatusPill(trip: trip)
                Spacer(minLength: Spacing.m)
                countdown
            }
            Spacer(minLength: Spacing.xxl)
            Text(trip.name)
                .font(Typography.display)
                .foregroundStyle(.white)
                .lineLimit(3)
            if !trip.destination.isEmpty {
                Label(trip.destination, systemImage: "mappin.and.ellipse")
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.92))
            }
            Text("\(Format.dateRange(trip.startDate, trip.endDate)) · \(dayCount) \(dayCount == 1 ? "day" : "days") · \(stopCount) \(stopCount == 1 ? "stop" : "stops")")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 300 * min(heroScale, 1.4), alignment: .bottomLeading)
        .background {
            ZStack {
                TripHeroImage(trip: trip)
                LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                       .init(color: .clear, location: 0.3),
                                       .init(color: .black.opacity(0.35), location: 0.6),
                                       .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .scaleEffect(1.2)
            // Parallax: the photo moves a little slower than the page. Off with Reduce Motion.
            .visualEffect { [reduce = reduceMotion] content, proxy in
                let minY = proxy.frame(in: .scrollView).minY
                return content.offset(y: reduce ? 0 : -min(minY, 0) * 0.3)
            }
        }
        .clipShape(Radius.shape(Radius.hero))
    }

    @ViewBuilder
    private var countdown: some View {
        if let days = trip.daysUntilStart {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(days)")
                    .font(Typography.display)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(days == 1 ? "day to go" : "days to go")
                    .font(Typography.caption)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: The one raised card

    @ViewBuilder
    private var primaryCard: some View {
        if trip.isActiveToday {
            todayCard
        } else if !trip.isPast {
            firstDayCard
        }
    }

    private var todayCard: some View {
        let day = trip.todayDay
        let remaining = day?.sortedStops.filter { !$0.isDone } ?? []

        return Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Today").eyebrow()

                if let next = remaining.first {
                    Text(next.name)
                        .font(Typography.title)
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: Spacing.m) {
                        if let time = next.plannedTime {
                            Label(Format.time(time), systemImage: "clock")
                        }
                        Label("\(remaining.count) left", systemImage: "list.bullet")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Theme.inkSecondary)
                } else if day?.stops.isEmpty ?? true {
                    Text("Nothing planned for today yet")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.ink)
                } else {
                    Label("All done for today", systemImage: "checkmark.seal.fill")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.success)
                }

                NavigationLink {
                    TodayView(trip: trip)
                } label: {
                    Label("Open Trip Mode", systemImage: "location.fill")
                }
                .buttonStyle(.primary)
            }
        }
    }

    private var firstDayCard: some View {
        let first = trip.sortedDays.first

        return Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Coming up").eyebrow()
                if let first, !first.stops.isEmpty {
                    Text("Day 1: \(first.stops.count) \(first.stops.count == 1 ? "stop" : "stops") planned")
                        .font(Typography.title)
                        .foregroundStyle(Theme.ink)
                    if let name = first.sortedStops.first?.name {
                        Text("Starting at \(name)")
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } else {
                    Text("Nothing planned for the first day yet")
                        .font(Typography.title)
                        .foregroundStyle(Theme.ink)
                    Button("Add places") { perform(.addPlaces) }
                        .buttonStyle(.primary(fullWidth: false))
                }
                NavigationLink {
                    TodayView(trip: trip)
                } label: {
                    Label("Preview Trip Mode", systemImage: "location.fill")
                }
                .buttonStyle(.secondary)
            }
        }
    }

    // MARK: Flights and hotel strip

    private var upcomingBookings: [Booking] {
        trip.bookings
            .filter { $0.keyDate > Date().addingTimeInterval(-6 * 3600) }
            .sorted { $0.keyDate < $1.keyDate }
    }

    @ViewBuilder
    private var bookingsStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Flights & hotel", actionTitle: "Manage") { perform(.bookings) }

            if upcomingBookings.isEmpty {
                Button {
                    perform(.bookings)
                } label: {
                    InfoRow(symbol: "airplane", title: "Add flights and hotel",
                            detail: "Day 1 can start when you land") {
                        Image(systemName: "chevron.right").foregroundStyle(Theme.inkSecondary)
                    }
                    .card(padding: Spacing.m)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.m) {
                        ForEach(upcomingBookings.prefix(6)) { booking in
                            bookingTile(booking)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private func bookingTile(_ booking: Booking) -> some View {
        Button {
            perform(.bookings)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(booking.kind.shortTitle, systemImage: booking.kind.symbol)
                    .eyebrow()
                Text(headline(for: booking))
                    .font(Typography.label)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(subline(for: booking))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: tileWidth, alignment: .leading)
            .card(padding: Spacing.m)
        }
        .buttonStyle(.plain)
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

    // MARK: Tools

    private var checklistDetail: String {
        guard !trip.checklist.isEmpty else { return "Start a list" }
        return "\(trip.checklist.filter(\.isDone).count) of \(trip.checklist.count) done"
    }

    private var toolsGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Tools")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible())],
                      spacing: Spacing.m) {
                toolTile("Packing & to-do", symbol: "checklist", detail: checklistDetail, action: .packing)
                toolTile("Documents", symbol: "folder",
                         detail: trip.documents.isEmpty ? "Tickets, bookings" : "\(trip.documents.count) saved",
                         action: .documents)
                toolTile("Import", symbol: "doc.viewfinder", detail: "From a PDF or photo", action: .importProgram)
                toolTile("Auto plan", symbol: "wand.and.stars", detail: "Fill the days for me", action: .autoPlan)
            }
        }
    }

    private func toolTile(_ title: String, symbol: String, detail: String, action: SetupAction) -> some View {
        Button {
            Haptics.select()
            perform(action)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Spacer(minLength: Spacing.xs)
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(minHeight: 96, alignment: .topLeading)
            .card(padding: Spacing.m)
        }
        .buttonStyle(.plain)
    }

    // MARK: Get ready

    @ViewBuilder
    private var setupSection: some View {
        let steps = TripSetupProgress.steps(for: trip)
        let done = steps.filter(\.isDone).count

        if done < steps.count {
            let next = steps.first { !$0.isDone }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Haptics.select()
                    Motion.perform { showSetup.toggle() }
                } label: {
                    HStack(spacing: Spacing.m) {
                        ProgressRing(progress: Double(done) / Double(max(steps.count, 1)))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get ready")
                                .font(Typography.headline)
                                .foregroundStyle(Theme.ink)
                            Text(next.map { "Next: \($0.title)" } ?? "\(done) of \(steps.count) done")
                                .font(Typography.label)
                                .foregroundStyle(Theme.inkSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: Spacing.s)
                        Text("\(done)/\(steps.count)")
                            .font(Typography.label)
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .rotationEffect(.degrees(showSetup ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Get ready, \(done) of \(steps.count) done")
                .accessibilityValue(showSetup ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the remaining steps")

                if showSetup {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(steps) { step in
                            setupRow(step)
                        }
                    }
                    .padding(.top, Spacing.s)
                    .transition(.opacity)
                }
            }
            .card()
        }
    }

    private func setupRow(_ step: SetupStep) -> some View {
        Button {
            if !step.isDone { perform(step.action) }
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(step.isDone ? Theme.success : Theme.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(Typography.body)
                        .strikethrough(step.isDone)
                        .foregroundStyle(step.isDone ? Theme.inkSecondary : Theme.ink)
                        .multilineTextAlignment(.leading)
                    if !step.isDone {
                        Text(step.detail)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Spacing.s)
                if !step.isDone {
                    Text(step.actionTitle)
                        .font(Typography.label)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(step.isDone)
    }

    // MARK: Good to know

    @ViewBuilder
    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Good to know")

            WeatherChip(date: trip.isActiveToday ? Date() : trip.startDate,
                        coordinate: trip.anyCoordinate)

            if trip.transport == .transit {
                TransitGuideCard(trip: trip)
            }

            if stopCount > 0 {
                OfflinePackCard(trip: trip)
            }

            if !trip.destination.isEmpty {
                PracticalInfoCard(trip: trip)
            }
        }
    }
}
