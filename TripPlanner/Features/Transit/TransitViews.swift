import SwiftUI
import MapKit

// MARK: - Colours and map segments

extension Color {
    /// "E4002B" -> Color
    init?(hex: String) {
        var value: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

extension Color {
    /// Black or white, whichever reads better on this colour. Agencies publish their own line colours, so
    /// the text on a badge can't be fixed. The 0.179 luminance threshold gives at least 4.5:1 either way.
    var readableForeground: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.179 ? .black : .white
    }
}

extension TransitLeg {
    /// The line's own colour when the agency publishes one, else a colour per kind of vehicle.
    var color: Color {
        if let colorHex, let color = Color(hex: colorHex) { return color }
        switch mode {
        case .walk: return Theme.day(7)
        case .bus: return Theme.day(0)
        case .tram: return Theme.day(1)
        case .subway: return Theme.day(3)
        case .rail: return Theme.day(5)
        case .ferry: return Theme.day(5)
        case .cableCar: return Theme.day(2)
        case .other: return Theme.day(6)
        }
    }
}

struct RouteSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let dashed: Bool
}

enum TransitPaths {
    static func segments(from itinerary: TransitItinerary, prefix: String,
                         walkOverrides: [Int: WalkOverride] = [:]) -> [RouteSegment] {
        itinerary.legs.enumerated().map { index, leg in
            RouteSegment(id: "\(prefix)-\(index)",
                         coordinates: walkOverrides[index]?.path ?? leg.coordinates,
                         color: leg.color,
                         dashed: leg.isWalking)
        }
    }
}

/// A walk that replaces the timetable's own: along real streets, to the station entrance.
struct WalkOverride {
    var path: [CLLocationCoordinate2D]
    var meters: Double
    /// Where it leads to or starts from, when that is an entrance.
    var entranceName: String?

    var seconds: Int { Int((meters / TransitSanity.walkingSpeed).rounded()) }

    static func length(of path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + RoutingService.straightLine(from: $1.0, to: $1.1) }
    }
}

/// The entrances chosen for one metro or train leg.
struct LegEntrances {
    var boarding: StationEntrance?
    var alighting: StationEntrance?
}

@MainActor
enum RouteDrawing {
    /// Each line is drawn twice: a wide light line underneath, then the coloured line, so it stays readable
    /// on any map. Walks are dotted.
    @MapContentBuilder
    static func lines(_ segments: [RouteSegment]) -> some MapContent {
        ForEach(segments) { segment in
            MapPolyline(coordinates: segment.coordinates)
                .stroke(Color.white.opacity(0.95),
                        style: StrokeStyle(lineWidth: segment.dashed ? 7 : 10, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: segment.coordinates)
                .stroke(segment.color,
                        style: StrokeStyle(lineWidth: segment.dashed ? 4 : 6, lineCap: .round, lineJoin: .round,
                                           dash: segment.dashed ? [0.5, 7] : []))
        }
    }

    /// A map rectangle around the points, with some air around it.
    static func rect(around points: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let first = points.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(point), size: MKMapSize(width: 0, height: 0)))
        }
        let paddingX = max(rect.size.width * 0.25, 400)
        let paddingY = max(rect.size.height * 0.25, 400)
        return rect.insetBy(dx: -paddingX, dy: -paddingY)
    }
}

/// A line name in the line's colour: "Tram 28", "M1".
struct TransitBadge: View {
    let leg: TransitLeg

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: leg.mode.symbol)
            Text(leg.routeShortName ?? leg.mode.title)
                .lineLimit(1)
        }
        .font(Typography.caption.bold())
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(leg.color, in: Radius.shape(Radius.small))
        .foregroundStyle(leg.color.readableForeground)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connector between two stops

/// One line under a stop: the best public transport route to the next stop. Tap for the details.
struct TransitConnector: View {
    let trip: Trip
    let fromName: String
    let toName: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    let timing: TransitTiming
    /// What to show until the route arrives (the straight-line estimate).
    let fallback: String
    var inset: CGFloat = 36
    /// Trip Mode: look again every minute while the screen is open, so live delays show.
    var liveRefresh = false
    var onDuration: ((TimeInterval?) -> Void)?
    /// The best route whenever it is looked up or refreshed (Trip Mode uses it for "Leave by").
    var onBest: ((TransitItinerary?) -> Void)?

    @State private var outcome: TransitOutcome?
    @State private var zone: TimeZone = .current
    @State private var showRoute = false

    private var taskKey: String {
        let when: String
        switch timing {
        case .now: when = "now"
        case .departAt(let date): when = "d\(Int(date.timeIntervalSince1970 / 60))"
        case .arriveBy(let date): when = "a\(Int(date.timeIntervalSince1970 / 60))"
        }
        return TransitRouter.pairKey(from, to) + when
    }

    var body: some View {
        Button {
            showRoute = true
        } label: {
            content
                .font(.caption)
                .padding(.leading, inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: taskKey) {
            outcome = nil
            zone = await TripTimeZone.ensure(trip)
            let result = await TransitRouter.lookup(from: from, to: to, timing: timing, timeZone: zone)
            guard !Task.isCancelled else { return }
            publish(result)
            guard liveRefresh else { return }
            await keepFresh()
        }
        .sheet(isPresented: $showRoute) {
            if let outcome {
                TransitRouteView(trip: trip, fromName: fromName, toName: toName, from: from, to: to, outcome: outcome)
            }
        }
    }

    private func publish(_ result: TransitOutcome) {
        outcome = result
        onDuration?(result.bestDuration)
        if case .routes(let routes) = result {
            onBest?(routes.best)
        } else {
            onBest?(nil)
        }
    }

    /// Asks for the latest times every minute: the same journey when the service knows it, else a new search.
    private func keepFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(LivePolicy.refreshInterval))
            guard !Task.isCancelled, case .routes(let current)? = outcome, let best = current.best else { continue }
            if let fresh = try? await TransitLive.refresh(best) {
                guard !Task.isCancelled else { return }
                publish(.routes(current.replacing(fresh, at: 0)))
            } else {
                let result = await TransitRouter.lookup(from: from, to: to, timing: timing, timeZone: zone, refresh: true)
                guard !Task.isCancelled else { return }
                publish(result)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .none:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.mini)
                Text(fallback).foregroundStyle(.tertiary)
            }
        case .routes(let result):
            if let best = result.best {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: best.headlineMode.symbol)
                        Text((result.isTypical ? "≈ " : "") + best.summary)
                            .lineLimit(2)
                    }
                    .foregroundStyle(Theme.inkSecondary)
                    if !result.isTypical, let first = best.transitLegs.first {
                        DepartureLine(leg: first, zone: result.timeZone)
                    }
                }
            }
        case .noCoverage(let estimate):
            Label(estimate.map { "No transit timetable here · about \(Format.duration($0))" }
                  ?? "No transit timetable for this area", systemImage: "tram.fill")
                .foregroundStyle(Theme.warning)
        case .failed:
            Label("Route unavailable · tap to see why", systemImage: "wifi.slash")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Route details

struct TransitRouteView: View {
    let trip: Trip
    let fromName: String
    let toName: String
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    let outcome: TransitOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var entrances: [Int: LegEntrances] = [:]
    @State private var walkOverrides: [Int: WalkOverride] = [:]
    @State private var walkPath: [CLLocationCoordinate2D]?
    /// Fresher times than the answer the sheet was opened with.
    @State private var liveResult: TransitResult?
    @State private var updatedAt: Date?
    @State private var updateFailed = false
    @State private var board: BoardTarget?

    private struct BoardTarget: Identifiable {
        var id: String { stopId }
        let stopId: String
        let name: String
        let line: String?
        let zone: TimeZone
    }

    private var baseResult: TransitResult? {
        if case .routes(let result) = outcome { return result }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("\(fromName) → \(toName)")
                        .font(.headline)

                    switch outcome {
                    case .routes(let result):
                        routes(liveResult ?? result, original: result)
                    case .noCoverage(let estimate):
                        message("No public transport timetable was found for this area",
                                detail: estimate.map { "Apple Maps estimates about \(Format.duration($0)) by public transport. " }
                                    ?? "The timetable data may not cover this place yet. ")
                    case .failed(let reason):
                        message("Couldn't load the route", detail: reason)
                    }

                    Button {
                        RoutingService.openInMaps(name: toName, coordinate: to, mode: .transit)
                    } label: {
                        Label("Open in Apple Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    TransitGuideCard(trip: trip)

                    Text("Routes from Transitous (transitous.org), built on the timetables of the transit agencies. Live times and delays appear where an agency shares them; otherwise times are the timetable's.")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding()
            }
            .refreshable {
                if let base = baseResult { await refreshNow(index: selected, base: base) }
            }
            .navigationTitle("Public transport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .sheet(item: $board) { target in
            DepartureBoardView(stopId: target.stopId, stopName: target.name, highlightLine: target.line, zone: target.zone)
        }
    }

    @ViewBuilder
    private func routes(_ result: TransitResult, original: TransitResult) -> some View {
        let itineraries = result.itineraries
        let index = min(selected, itineraries.count - 1)
        let current = itineraries[index]

        if itineraries.count > 1 {
            Picker("Option", selection: $selected) {
                ForEach(Array(itineraries.enumerated()), id: \.offset) { number, itinerary in
                    Text(optionTitle(itinerary, number: number)).tag(number)
                }
            }
            .pickerStyle(.segmented)
        }

        RouteMap(itinerary: current, from: from, to: to, walkOverrides: walkOverrides, entrances: entrances,
                 plainWalk: walkPath)
            .id(current.id ?? "\(index)-\(current.duration)")
            .frame(height: 280)
            .clipShape(Radius.shape(Radius.card))
            .task(id: current.id ?? "\(index)-\(current.duration)") { await loadExtras(current) }

        alerts(current, in: itineraries)

        header(current, result: result)
            .task(id: current.id ?? "\(index)") { await liveLoop(index: index, base: original) }

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(current.legs.enumerated()), id: \.offset) { number, leg in
                LegRow(leg: leg, zone: result.timeZone,
                       walkOverride: walkOverrides[number],
                       entrances: entrances[number]) { tapped in
                    guard let stopId = tapped.fromStopId else { return }
                    board = BoardTarget(stopId: stopId, name: tapped.fromName, line: tapped.routeShortName, zone: result.timeZone)
                }
            }
        }
        .card()

        if entrances.values.contains(where: { $0.boarding != nil || $0.alighting != nil }) {
            Text("Station entrances: Apple Maps where it lists them, otherwise OpenStreetMap contributors (ODbL).")
                .font(.caption2)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private func optionTitle(_ itinerary: TransitItinerary, number: Int) -> String {
        let time = Format.duration(TimeInterval(itinerary.duration))
        return itinerary.transitLegs.isEmpty ? "Walk \(time)" : time
    }

    /// Total time, changes and walking, at a glance.
    private func header(_ current: TransitItinerary, result: TransitResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                chip(Format.duration(TimeInterval(current.duration)), "clock")
                if !current.transitLegs.isEmpty {
                    chip(current.transfers == 0 ? "Direct" : "\(current.transfers) \(current.transfers == 1 ? "change" : "changes")",
                         "arrow.triangle.swap")
                    chip("\(Format.duration(TimeInterval(current.walkingSeconds))) walking", "figure.walk")
                }
            }
            if !current.transitLegs.isEmpty {
                Text(current.transitLegs.map(\.label).joined(separator: " → "))
                    .font(.subheadline.bold())
            }
            if let start = current.start, let end = current.end {
                Text("\(TransitTime.timeText(start, in: result.timeZone)) → \(TransitTime.timeText(end, in: result.timeZone))")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if current.transitLegs.isEmpty {
                Label("Walking is about as fast as public transport here.", systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            liveCaption(current, result: result)
            if result.isTypical {
                Label("Your date is too far ahead for timetables. This is the typical timetable for that weekday and time.",
                      systemImage: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    /// Says whether the times are live, and when they were last read.
    @ViewBuilder
    private func liveCaption(_ current: TransitItinerary, result: TransitResult) -> some View {
        if current.hasLiveData {
            let read = max(updatedAt ?? .distantPast, result.fetchedAt)
            Label("Live times · updated \(TransitTime.timeText(read, in: result.timeZone))",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(Theme.success)
            if updateFailed {
                Text("The last update didn't work. These are the latest times known.")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
        } else if let first = current.firstDeparture, LivePolicy.isLive(departure: first) {
            Label("Timetable times. This agency doesn't share live data.", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    /// A cancelled vehicle, or a change that is too tight with today's delays.
    @ViewBuilder
    private func alerts(_ current: TransitItinerary, in all: [TransitItinerary]) -> some View {
        if current.hasCancelledLeg {
            Banner(kind: .danger, title: "A vehicle on this route is cancelled.") {
                if let other = all.firstIndex(where: { !$0.hasCancelledLeg }) {
                    Button("Show the next option") { selected = other }
                        .buttonStyle(.secondary(fullWidth: false))
                        .padding(.top, Spacing.xs)
                }
            }
        }
        let tight = current.changeSlackMinutes.filter { $0 < 3 }
        if !tight.isEmpty && !current.hasCancelledLeg {
            Banner(kind: .warning, title: tightText(tight))
        }
    }

    private func tightText(_ slack: [Int]) -> String {
        let shortest = slack.min() ?? 0
        if shortest < 1 { return "You may miss a connection: the change is shorter than the walk." }
        return "Tight change: only \(shortest) min between vehicles."
    }

    /// While the sheet is open and the departure is close, read the live times again every minute.
    private func liveLoop(index: Int, base: TransitResult) async {
        while !Task.isCancelled {
            let current = liveResult ?? base
            guard current.itineraries.indices.contains(index),
                  let first = current.itineraries[index].firstDeparture ?? current.itineraries[index].start,
                  LivePolicy.isLive(departure: first) else { return }
            try? await Task.sleep(for: .seconds(LivePolicy.refreshInterval))
            if Task.isCancelled { return }
            await refreshNow(index: index, base: base)
        }
    }

    private func refreshNow(index: Int, base: TransitResult) async {
        let current = liveResult ?? base
        guard current.itineraries.indices.contains(index) else { return }
        if let fresh = try? await TransitLive.refresh(current.itineraries[index]) {
            liveResult = current.replacing(fresh, at: index)
            updatedAt = Date()
            updateFailed = false
        } else {
            updateFailed = current.itineraries[index].hasLiveData
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Typography.label)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 0.5))
    }

    /// Station entrances and street-level walking paths for the chosen route.
    private func loadExtras(_ itinerary: TransitItinerary) async {
        entrances = [:]
        walkOverrides = [:]
        walkPath = nil

        // A walk-only answer has no line of its own: ask Apple Maps for the real streets.
        if itinerary.transitLegs.isEmpty, itinerary.legs.first?.path.isEmpty ?? false {
            walkPath = await WalkingPath.fetch(from: from, to: to)
        }

        for (index, leg) in itinerary.legs.enumerated() where leg.mode == .subway || leg.mode == .rail {
            // Where you come from: the start of the walk before, or where the vehicle before let you off.
            let cameFrom: CLLocationCoordinate2D
            if index > 0 {
                let before = itinerary.legs[index - 1]
                cameFrom = before.isWalking ? before.from.coordinate : before.to.coordinate
            } else {
                cameFrom = from
            }
            let goingTo: CLLocationCoordinate2D
            if index + 1 < itinerary.legs.count {
                let after = itinerary.legs[index + 1]
                goingTo = after.isWalking ? after.to.coordinate : after.from.coordinate
            } else {
                goingTo = to
            }

            let boardingList = await TransitEntrances.find(stationName: leg.fromName, near: leg.from.coordinate)
            let alightingList = await TransitEntrances.find(stationName: leg.toName, near: leg.to.coordinate)
            if Task.isCancelled { return }
            // Answers for another journey (the traveller switched option) are dropped.
            let shownID = (liveResult ?? baseResult)?.itineraries[safe: selected]?.id
            if let id = itinerary.id, id != shownID { return }

            var choice = LegEntrances()
            choice.boarding = TransitEntrances.nearest(boardingList.filter(\.isEntrance), to: cameFrom)
            choice.alighting = TransitEntrances.nearest(alightingList.filter(\.isEntrance), to: goingTo)
            guard choice.boarding != nil || choice.alighting != nil else { continue }
            entrances[index] = choice

            // The walk before and after goes to and from the entrance, along real streets.
            if let door = choice.boarding, index > 0, itinerary.legs[index - 1].isWalking,
               let path = await WalkingPath.fetch(from: cameFrom, to: door.coordinate) {
                walkOverrides[index - 1] = WalkOverride(path: path, meters: WalkOverride.length(of: path), entranceName: door.name)
            }
            if let door = choice.alighting, index + 1 < itinerary.legs.count, itinerary.legs[index + 1].isWalking,
               let path = await WalkingPath.fetch(from: door.coordinate, to: goingTo) {
                walkOverrides[index + 1] = WalkOverride(path: path, meters: WalkOverride.length(of: path), entranceName: nil)
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(Theme.warning)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
        .card()
    }
}

/// One step of the journey, on a timeline: a coloured rail for a vehicle, a dotted one for a walk.
private struct LegRow: View {
    let leg: TransitLeg
    let zone: TimeZone
    var walkOverride: WalkOverride?
    var entrances: LegEntrances?
    /// Tapping the boarding stop of a vehicle opens its departure board.
    var onDepartures: ((TransitLeg) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .trailing, spacing: 0) {
                LiveTime(date: leg.departure, delay: leg.departureDelayMinutes, cancelled: leg.isCancelled, zone: zone)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Spacer(minLength: 0)
                if !leg.isWalking {
                    LiveTime(date: leg.arrival, delay: leg.arrivalDelayMinutes, cancelled: leg.isCancelled, zone: zone)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: 58, alignment: .trailing)

            Rail(color: leg.color, dotted: leg.isWalking)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if leg.isWalking {
                    walkText
                } else {
                    vehicleText
                }
            }
            .padding(.vertical, Spacing.s)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var walkText: some View {
        let seconds = walkOverride?.seconds ?? leg.duration
        let meters = walkOverride?.meters ?? leg.distance
        Label("Walk \(Format.duration(TimeInterval(seconds))) · \(Format.distance(meters))", systemImage: "figure.walk")
            .font(.subheadline)
        if let entrance = walkOverride?.entranceName {
            Label("to \(entrance)", systemImage: "door.left.hand.open")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
        } else {
            Text("to \(leg.toName)")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    @ViewBuilder
    private var vehicleText: some View {
        HStack(spacing: Spacing.s) {
            TransitBadge(leg: leg)
            if let headsign = leg.headsign {
                Text("towards \(headsign)")
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        if leg.fromStopId != nil, let onDepartures {
            Button {
                onDepartures(leg)
            } label: {
                Label(leg.fromName, systemImage: "list.bullet.clipboard")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the next departures from this stop")
        } else {
            Text(leg.fromName)
                .font(.subheadline.weight(.medium))
        }
        statusLine
        if let door = entrances?.boarding {
            Label("Go in at \(door.name)", systemImage: "door.left.hand.open")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        Text([leg.stopCount > 0 ? "\(leg.stopCount + 1) stops" : nil,
              Format.duration(TimeInterval(leg.duration)), leg.agencyName]
            .compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(Theme.inkSecondary)
        Text(leg.toName)
            .font(.subheadline.weight(.medium))
        if let door = entrances?.alighting {
            Label("Come out at \(door.name)", systemImage: "door.right.hand.open")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    /// Live, late, cancelled or just the timetable.
    @ViewBuilder
    private var statusLine: some View {
        switch leg.status {
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(Theme.danger)
        case .late(let minutes):
            Label("\(minutes) min late", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .foregroundStyle(Theme.danger)
        case .early(let minutes):
            Label("\(minutes) min early", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .foregroundStyle(Theme.warning)
        case .onTime:
            Label("On time · live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .foregroundStyle(Theme.success)
        case .scheduled:
            EmptyView()
        }
    }
}

/// A time with its delay next to it ("09:35 +1"), struck through when the vehicle is cancelled.
struct LiveTime: View {
    let date: Date?
    let delay: Int?
    var cancelled = false
    let zone: TimeZone

    var body: some View {
        if let date {
            HStack(spacing: 3) {
                Text(TransitTime.timeText(date, in: zone))
                    .strikethrough(cancelled)
                    .foregroundStyle(cancelled ? Theme.danger : Theme.ink)
                if let delay, delay != 0, !cancelled {
                    Text(delay > 0 ? "+\(delay)" : "\(delay)")
                        .font(.caption2.bold())
                        .foregroundStyle(delay > 0 ? Theme.danger : Theme.success)
                }
            }
        }
    }
}

/// "leaves 09:35 +1 · in 4 min": when the first vehicle goes, counting down while the screen is open.
struct DepartureLine: View {
    let leg: TransitLeg
    let zone: TimeZone

    var body: some View {
        if let departure = leg.departure {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: Spacing.xs) {
                    if leg.isCancelled {
                        Label("Cancelled", systemImage: "xmark.circle.fill")
                            .foregroundStyle(Theme.danger)
                    } else {
                        Text("leaves")
                            .foregroundStyle(Theme.inkSecondary)
                        LiveTime(date: departure, delay: leg.departureDelayMinutes, zone: zone)
                        if LivePolicy.isLive(departure: departure, now: context.date) {
                            Text("· " + TransitLive.countdownText(until: departure, now: context.date))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        if leg.isLive {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.success)
                        }
                    }
                }
                .font(.caption2)
            }
        }
    }
}

/// The line down the side of a timeline step. It stretches to the height of the step.
private struct Rail: View {
    let color: Color
    let dotted: Bool

    var body: some View {
        RailLine()
            .stroke(color, style: StrokeStyle(lineWidth: dotted ? 3 : 6, lineCap: .round, dash: dotted ? [0.5, 6] : []))
            .frame(width: 10)
            .frame(maxHeight: .infinity)
    }
}

private struct RailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

private struct RouteMap: View {
    let itinerary: TransitItinerary
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    var walkOverrides: [Int: WalkOverride] = [:]
    var entrances: [Int: LegEntrances] = [:]
    /// The streets of a walk-only route, when Apple Maps found them.
    var plainWalk: [CLLocationCoordinate2D]?

    private var segments: [RouteSegment] {
        var list = TransitPaths.segments(from: itinerary, prefix: "r", walkOverrides: walkOverrides)
        if let plainWalk, itinerary.transitLegs.isEmpty, !list.isEmpty {
            list[0] = RouteSegment(id: list[0].id, coordinates: plainWalk, color: list[0].color, dashed: true)
        }
        return list
    }

    private var allPoints: [CLLocationCoordinate2D] {
        segments.flatMap(\.coordinates) + [from, to]
    }

    var body: some View {
        let lines = segments
        Map(initialPosition: ownPosition) {
            RouteDrawing.lines(lines)

            ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { index, leg in
                if !leg.isWalking {
                    // Where the vehicle is boarded and left.
                    Annotation(leg.fromName, coordinate: leg.from.coordinate, anchor: .center) {
                        Pin(kind: .station(symbol: leg.mode.symbol, large: true), tint: leg.color)
                    }
                    Annotation(leg.toName, coordinate: leg.to.coordinate, anchor: .center) {
                        Pin(kind: .station(symbol: nil, large: false), tint: leg.color)
                    }
                    // The line's name on the line itself.
                    if let middle = leg.coordinates[safe: leg.coordinates.count / 2] {
                        Annotation("", coordinate: middle, anchor: .center) {
                            TransitBadge(leg: leg)
                                .scaleEffect(0.85)
                        }
                    }
                }
                if let choice = entrances[index] {
                    if let door = choice.boarding {
                        Annotation(door.name, coordinate: door.coordinate, anchor: .center) {
                            Pin(kind: .entrance(boarding: true), tint: leg.color)
                        }
                    }
                    if let door = choice.alighting {
                        Annotation(door.name, coordinate: door.coordinate, anchor: .center) {
                            Pin(kind: .entrance(boarding: false), tint: leg.color)
                        }
                    }
                }
            }

            Annotation("Start", coordinate: from, anchor: .center) {
                Pin(kind: .start)
            }
            Annotation("Destination", coordinate: to, anchor: .center) {
                Pin(kind: .end)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.publicTransport])))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    /// Frames the whole route.
    private var ownPosition: MapCameraPosition {
        if let rect = RouteDrawing.rect(around: allPoints) { return .rect(rect) }
        return .automatic
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - How public transport works here

struct TransitGuideCard: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @State private var loading = false
    @State private var expanded = false
    @State private var missing = false

    private var notes: TransitNotes? {
        guard !trip.transitNotes.isEmpty else { return nil }
        return try? JSONDecoder().decode(TransitNotes.self, from: Data(trip.transitNotes.utf8))
    }

    private var city: String { TransitGuide.parts(of: trip.destination).city }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Public transport in \(city.isEmpty ? "your destination" : city)", systemImage: "tram.fill")
                .font(.headline)

            if let notes, !notes.isEmpty {
                noteList("Tickets", "ticket", notes.tickets)
                noteList("Apps", "iphone", notes.apps)
                noteList("Tips", "lightbulb", notes.tips)
            }

            if !trip.transitGuide.isEmpty {
                if notes == nil || expanded {
                    Text(trip.transitGuide)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(expanded ? nil : 8)
                }
                if notes != nil || trip.transitGuide.count > 400 {
                    Button(expanded ? "Show less" : (notes == nil ? "Show more" : "Show the original text")) {
                        expanded.toggle()
                    }
                    .font(.footnote.bold())
                }
                HStack(spacing: Spacing.xs) {
                    Text("From Wikivoyage (CC BY-SA)")
                    if let url = URL(string: "https://en.wikivoyage.org/wiki/\(trip.transitGuideTitle.replacingOccurrences(of: " ", with: "_"))#Get_around") {
                        Link("Read more", destination: url)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.inkSecondary)
            } else if loading {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Loading the travel guide…")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            } else if missing {
                Text("No travel guide with public transport information was found for this destination.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .card()
        .task(id: trip.destination) {
            guard !trip.destination.isEmpty else { return }
            loading = trip.transitGuide.isEmpty
            await TransitGuide.ensure(for: trip, geminiKey: secrets.keys.gemini)
            loading = false
            missing = trip.transitGuide.isEmpty
        }
    }

    @ViewBuilder
    private func noteList(_ title: String, _ symbol: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(Theme.inkSecondary)
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: symbol)
                        .font(.subheadline)
                }
            }
        }
    }
}
