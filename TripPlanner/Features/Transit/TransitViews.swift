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

extension TransitLeg {
    /// The line's own colour when the agency publishes one, else a colour per kind of vehicle.
    var color: Color {
        if let colorHex, let color = Color(hex: colorHex) { return color }
        switch mode {
        case .walk: return .gray
        case .bus: return .blue
        case .tram: return .orange
        case .subway: return .red
        case .rail: return .green
        case .ferry: return .teal
        case .cableCar: return .purple
        case .other: return .indigo
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
    static func segments(from itinerary: TransitItinerary, prefix: String) -> [RouteSegment] {
        itinerary.legs.enumerated().map { index, leg in
            RouteSegment(id: "\(prefix)-\(index)", coordinates: leg.coordinates, color: leg.color, dashed: leg.isWalking)
        }
    }
}

/// A line name in the line's colour: "Tram 28", "M1".
struct TransitBadge: View {
    let leg: TransitLeg

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: leg.mode.symbol)
            Text(leg.routeShortName ?? leg.mode.title)
                .lineLimit(1)
        }
        .font(.caption.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(leg.color, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(.white)
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
    var onDuration: ((TimeInterval?) -> Void)?

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
            zone = await TripTimeZone.ensure(trip)
            let result = await TransitRouter.lookup(from: from, to: to, timing: timing, timeZone: zone)
            outcome = result
            onDuration?(result.bestDuration)
        }
        .sheet(isPresented: $showRoute) {
            if let outcome {
                TransitRouteView(trip: trip, fromName: fromName, toName: toName, from: from, to: to, outcome: outcome)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .none:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(fallback).foregroundStyle(.tertiary)
            }
        case .routes(let result):
            if let best = result.best {
                HStack(spacing: 6) {
                    Image(systemName: best.headlineMode.symbol)
                    Text((result.isTypical ? "≈ " : "") + best.summary)
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
            }
        case .noCoverage(let estimate):
            Label(estimate.map { "No transit timetable here · about \(Format.duration($0))" }
                  ?? "No transit timetable for this area", systemImage: "tram.fill")
                .foregroundStyle(.orange)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(fromName) → \(toName)")
                        .font(.headline)

                    switch outcome {
                    case .routes(let result):
                        routes(result)
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

                    Text("Routes from Transitous (transitous.org), built on the timetables of the transit agencies. Scheduled times; delays aren't included.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
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
    }

    @ViewBuilder
    private func routes(_ result: TransitResult) -> some View {
        let itineraries = result.itineraries
        let current = itineraries[min(selected, itineraries.count - 1)]

        if itineraries.count > 1 {
            Picker("Option", selection: $selected) {
                ForEach(Array(itineraries.enumerated()), id: \.offset) { index, itinerary in
                    Text(Format.duration(TimeInterval(itinerary.duration))).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }

        RouteMap(itinerary: current, from: from, to: to)
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))

        VStack(alignment: .leading, spacing: 4) {
            Text(current.summary)
                .font(.subheadline.bold())
            if let start = current.start, let end = current.end {
                Text("\(TransitTime.timeText(start, in: result.timeZone)) → \(TransitTime.timeText(end, in: result.timeZone))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if result.isTypical {
                Label("Your date is too far ahead for timetables. This is the typical timetable for that weekday and time.",
                      systemImage: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(current.legs.enumerated()), id: \.offset) { index, leg in
                LegRow(leg: leg, zone: result.timeZone)
                if index < current.legs.count - 1 { Divider() }
            }
        }
        .card()
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

private struct LegRow: View {
    let leg: TransitLeg
    let zone: TimeZone

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if leg.isWalking {
                Image(systemName: "figure.walk")
                    .frame(width: 44)
                    .foregroundStyle(.secondary)
            } else {
                TransitBadge(leg: leg)
                    .frame(width: 70, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                if leg.isWalking {
                    Text("Walk \(Format.duration(TimeInterval(leg.duration))) · \(Format.distance(leg.distance))")
                        .font(.subheadline)
                    Text("to \(leg.toName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if let headsign = leg.headsign {
                        Text("towards \(headsign)")
                            .font(.subheadline)
                    }
                    Text("\(time(leg.departure)) \(leg.fromName)")
                        .font(.caption)
                    Text("\(time(leg.arrival)) \(leg.toName)")
                        .font(.caption)
                    Text([leg.stopCount > 0 ? "\(leg.stopCount + 1) stops" : nil, leg.agencyName]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func time(_ date: Date?) -> String {
        date.map { TransitTime.timeText($0, in: zone) } ?? "--:--"
    }
}

private struct RouteMap: View {
    let itinerary: TransitItinerary
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D

    var body: some View {
        Map {
            ForEach(TransitPaths.segments(from: itinerary, prefix: "r")) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: segment.dashed ? [2, 7] : []))
            }
            ForEach(Array(itinerary.transitLegs.enumerated()), id: \.offset) { _, leg in
                Annotation(leg.fromName, coordinate: leg.from.coordinate) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(leg.color, lineWidth: 3))
                }
                Annotation(leg.toName, coordinate: leg.to.coordinate) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(leg.color, lineWidth: 3))
                }
            }
            Marker("Start", systemImage: "figure.walk", coordinate: from)
                .tint(.green)
            Marker("Destination", systemImage: "flag.fill", coordinate: to)
                .tint(.red)
        }
        .mapControls {
            MapCompass()
        }
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
        VStack(alignment: .leading, spacing: 10) {
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
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 8)
                }
                if notes != nil || trip.transitGuide.count > 400 {
                    Button(expanded ? "Show less" : (notes == nil ? "Show more" : "Show the original text")) {
                        expanded.toggle()
                    }
                    .font(.footnote.bold())
                }
                HStack(spacing: 4) {
                    Text("From Wikivoyage (CC BY-SA)")
                    if let url = URL(string: "https://en.wikivoyage.org/wiki/\(trip.transitGuideTitle.replacingOccurrences(of: " ", with: "_"))#Get_around") {
                        Link("Read more", destination: url)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading the travel guide…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if missing {
                Text("No travel guide with public transport information was found for this destination.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: symbol)
                        .font(.subheadline)
                }
            }
        }
    }
}
