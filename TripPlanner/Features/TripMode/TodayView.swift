import SwiftUI
import SwiftData
import CoreLocation

/// The tour-guide screen: what's next today, how to get there, and a shortcut to food.
struct TodayView: View {
    @Bindable var trip: Trip

    @Environment(LocationService.self) private var location
    @AppStorage("nudgesEnabled") private var nudgesEnabled = false
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled = false

    @State private var selectedDayID: PersistentIdentifier?
    @State private var mode: TravelMode = .walk
    @State private var etas: [TravelMode: TimeInterval] = [:]
    @State private var showHungry = false
    @State private var dismissedReflow = false
    @State private var editingStop: Stop?
    @State private var showExpense = false
    @State private var nearbyKind: NearbyKind?
    @State private var showWhatNow = false
    @State private var transitDuration: TimeInterval?

    // MARK: Derived state

    private var days: [Day] { trip.sortedDays }

    private var day: Day? {
        if let selectedDayID, let match = days.first(where: { $0.persistentModelID == selectedDayID }) {
            return match
        }
        return trip.todayDay ?? days.first
    }

    private var isToday: Bool {
        day.map { Calendar.current.isDateInToday($0.date) } ?? false
    }

    private var remaining: [Stop] {
        day?.sortedStops.filter { !$0.isDone } ?? []
    }

    private var nextStop: Stop? { remaining.first }

    private var doneCount: Int {
        day?.stops.filter(\.isDone).count ?? 0
    }

    /// Your position, but only when you're actually at the trip's destination (within 100 km).
    private var userCoordinate: CLLocationCoordinate2D? {
        guard let user = location.coordinate else { return nil }
        guard let destination = trip.destinationCoordinate else { return user }
        return RoutingService.straightLine(from: user, to: destination) < 100_000 ? user : nil
    }

    private var isAwayFromDestination: Bool {
        location.coordinate != nil && userCoordinate == nil
    }

    private var distanceToNext: CLLocationDistance? {
        guard let from = userCoordinate, let to = nextStop?.coordinate else { return nil }
        return RoutingService.straightLine(from: from, to: to)
    }

    /// Where "hungry" searches start: you, or failing that the next stop.
    private var searchOrigin: CLLocationCoordinate2D? {
        userCoordinate ?? nextStop?.coordinate ?? trip.anyCoordinate
    }

    /// Changes when the next stop or the user's position (roughly 100 m) changes.
    private var etaKey: String {
        let id = nextStop.map { "\($0.persistentModelID.hashValue)" } ?? "none"
        let lat = userCoordinate.map { String(format: "%.3f", $0.latitude) } ?? "-"
        let lon = userCoordinate.map { String(format: "%.3f", $0.longitude) } ?? "-"
        return "\(id)-\(lat)-\(lon)"
    }

    /// Changes whenever reminders or the live activity need to be refreshed.
    private var smartKey: String {
        let stops = remaining.map {
            "\($0.persistentModelID.hashValue)@\($0.plannedTime?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ",")
        return "\(nudgesEnabled)-\(liveActivityEnabled)-\(isToday)-\(stops)-\(etaKey)"
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            if let day {
                VStack(spacing: 16) {
                    header(for: day)

                    quickActions

                    logisticsToday(for: day)

                    DayAlertsView(trip: trip, day: day)

                    if location.isDenied {
                        Label("Location is off. Enable it in Settings for travel times and nearby search.",
                              systemImage: "location.slash")
                            .font(.footnote)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if isAwayFromDestination {
                        Label("You're not at \(trip.destination.isEmpty ? "your destination" : trip.destination) yet. Travel times and nearby search use the trip's destination.",
                              systemImage: "airplane")
                            .font(.footnote)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }

                    StopsMapView(stops: day.sortedStops, showsUser: true, highlighted: nextStop,
                                 dayIndex: days.firstIndex(where: { $0.persistentModelID == day.persistentModelID }) ?? 0,
                                 start: trip.window(for: day.date).anchor,
                                 startName: trip.window(for: day.date).anchorName)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if isToday {
                        reflowBanner
                    }

                    if let next = nextStop {
                        NextUpCard(stop: next,
                                   mode: $mode,
                                   etas: etas,
                                   distance: distanceToNext,
                                   transitTrip: trip,
                                   origin: userCoordinate,
                                   transitDuration: $transitDuration) {
                            next.isDone = true
                            dismissedReflow = false
                        }
                    } else {
                        allDoneCard(hasStops: !day.stops.isEmpty)
                    }

                    WeatherChip(date: day.date,
                                coordinate: userCoordinate ?? day.sortedStops.first?.coordinate ?? trip.anyCoordinate,
                                outdoorStops: remaining.filter { $0.category.isOutdoor }.count)

                    DayTimelineView(stops: day.sortedStops) { editingStop = $0 }
                }
                .padding()
            } else {
                ContentUnavailableView("No days", systemImage: "calendar",
                                       description: Text("Edit the trip dates to add days."))
            }
        }
        .navigationTitle("Trip Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            Button {
                showHungry = true
            } label: {
                Label("I'm hungry", systemImage: "fork.knife")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(radius: 4, y: 2)
            }
            .padding()
            .disabled(day == nil)
        }
        .sheet(isPresented: $showHungry) {
            if let day {
                HungryView(day: day, origin: searchOrigin)
            }
        }
        .sheet(item: $editingStop) { stop in
            StopDetailView(stop: stop)
        }
        .sheet(isPresented: $showWhatNow) {
            if let day {
                WhatNowView(day: day, origin: searchOrigin, remaining: remaining)
            }
        }
        .sheet(item: $nearbyKind) { kind in
            if let day {
                NearbyView(kind: kind, origin: searchOrigin, day: day)
            }
        }
        .sensoryFeedback(.success, trigger: doneCount)
        .sheet(isPresented: $showExpense) {
            ExpenseEditView(trip: trip, expense: nil, defaultDate: isToday ? Date() : (day?.date ?? Date()))
        }
        .onAppear {
            location.start()
            switch trip.transport {
            case .transit: mode = .transit
            case .car: mode = .drive
            case .walking: break
            }
        }
        .task(id: etaKey) { await loadETAs() }
        .task(id: smartKey) { await syncSmartFeatures() }
    }

    // MARK: Pieces

    private func header(for day: Day) -> some View {
        let index = (days.firstIndex(where: { $0.persistentModelID == day.persistentModelID }) ?? 0) + 1
        let total = day.stops.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Today" : day.date.formatted(.dateTime.weekday(.wide)))
                .font(.largeTitle.bold())
            Text("\(trip.name) · Day \(index) of \(days.count) · \(day.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if total > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: Double(doneCount), total: Double(total))
                    Text("\(doneCount)/\(total) done")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Landing, check-in/out and the time to leave for the airport, when they fall on this day.
    @ViewBuilder
    private func logisticsToday(for day: Day) -> some View {
        let window = trip.window(for: day.date)
        if !window.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("TRAVEL TODAY")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(window.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        Text(TripLogistics.timeText(item.minute))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(item.text)
                    }
                    .font(.subheadline)
                }
                if let flight = trip.bookings.first(where: {
                    $0.kind == .departureFlight && $0.hasCoordinate
                        && Calendar.current.isDate($0.startDate, inSameDayAs: day.date)
                }), let airport = flight.coordinate {
                    Button {
                        RoutingService.openInMaps(name: flight.placeName.isEmpty ? "Airport" : flight.placeName,
                                                  coordinate: airport,
                                                  mode: .transit)
                    } label: {
                        Label("Directions to the airport", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .card()
        }
    }

    /// One-tap lookups for things you need on the road.
    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showWhatNow = true
                } label: {
                    Label("What now?", systemImage: "wand.and.stars")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                ForEach(NearbyKind.allCases) { kind in
                    Button {
                        nearbyKind = kind
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var reflowBanner: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = remaining.map { ScheduleItem(planned: $0.plannedTime, durationMinutes: $0.durationMinutes) }
            if !dismissedReflow,
               let late = ScheduleService.lateness(items: items, now: context.date),
               late >= 10 * 60 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("You're about \(Format.duration(late)) behind schedule", systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline.bold())
                    Text("Shift the rest of today's stops so nothing overlaps?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Re-flow day") { applyReflow(now: context.date) }
                            .buttonStyle(.borderedProminent)
                        Button("Dismiss") { dismissedReflow = true }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func allDoneCard(hasStops: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: hasStops ? "checkmark.seal.fill" : "calendar.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(hasStops ? Color.green : Color.secondary)
            Text(hasStops ? "All done for this day" : "Nothing planned")
                .font(.headline)
            Text(hasStops ? "Hungry? Tap the button below." : "Add places in the planner, or find food nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Day") {
                    ForEach(Array(days.enumerated()), id: \.element.persistentModelID) { index, d in
                        Button("Day \(index + 1) · \(Format.dayChip(d.date))") {
                            selectedDayID = d.persistentModelID
                            dismissedReflow = false
                        }
                    }
                }
                Button("Add expense", systemImage: "creditcard") { showExpense = true }
                Section("Smart features") {
                    Toggle("Departure reminders (walking)", isOn: nudgeBinding)
                    if AppFeatures.liveActivities {
                        Toggle("Lock screen countdown", isOn: $liveActivityEnabled)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var nudgeBinding: Binding<Bool> {
        Binding(
            get: { nudgesEnabled },
            set: { on in
                if on {
                    Task { nudgesEnabled = await NudgeService.requestAuthorization() }
                } else {
                    nudgesEnabled = false
                }
            }
        )
    }

    // MARK: Actions

    private func loadETAs() async {
        guard let from = userCoordinate, let to = nextStop?.coordinate else {
            etas = [:]
            return
        }
        var result: [TravelMode: TimeInterval] = [:]
        await withTaskGroup(of: (TravelMode, TimeInterval?).self) { group in
            for travelMode in TravelMode.allCases {
                group.addTask { (travelMode, await RoutingService.eta(from: from, to: to, mode: travelMode)) }
            }
            for await (travelMode, eta) in group {
                if let eta { result[travelMode] = eta }
            }
        }
        // Apple Maps has no transit/driving data everywhere; fall back to an estimate.
        for travelMode in TravelMode.allCases where result[travelMode] == nil {
            result[travelMode] = RoutingService.estimate(from: from, to: to, mode: travelMode)
        }
        etas = result
    }

    private func applyReflow(now: Date) {
        let stops = remaining
        let items = stops.map { ScheduleItem(planned: $0.plannedTime, durationMinutes: $0.durationMinutes) }
        for proposal in ScheduleService.reflow(items: items, now: now) {
            stops[proposal.index].plannedTime = proposal.newTime
        }
        dismissedReflow = false
    }

    private func syncSmartFeatures() async {
        if nudgesEnabled && isToday {
            let inputs = remaining.compactMap { stop -> NudgeService.Input? in
                guard let planned = stop.plannedTime, planned > Date() else { return nil }
                return NudgeService.Input(title: stop.name, planned: planned, coordinate: stop.coordinate)
            }
            await NudgeService.reschedule(inputs, origin: userCoordinate)
        } else {
            await NudgeService.cancelAll()
        }

        if AppFeatures.liveActivities && liveActivityEnabled && isToday {
            await LiveActivityManager.sync(tripName: trip.name, next: nextStop, stopsLeft: remaining.count)
        } else {
            await LiveActivityManager.end()
        }
    }
}
