import SwiftUI
import SwiftData
import MapKit

/// A colour per day, used on the full-screen map. The colours live in `Theme.day`.
enum DayPalette {
    static func color(_ index: Int) -> Color {
        Theme.day(index)
    }
}

/// Full-screen map of one day or the whole trip. Turn on "Drop pin", tap the map and add the
/// spot to a day.
struct DayMapView: View {
    @Bindable var trip: Trip
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Int = -1          // -1 = all days
    @State private var camera: MapCameraPosition = .automatic
    @State private var dropMode = false
    @State private var showTransit = false
    @State private var segments: [RouteSegment] = []
    @State private var pending: PendingPin?
    @State private var selected: Stop?

    private struct PendingPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        var name: String
        var address: String
    }

    private var days: [Day] { trip.sortedDays }

    private struct Entry: Identifiable {
        let index: Int
        let day: Day
        var id: PersistentIdentifier { day.persistentModelID }
    }

    private var visible: [Entry] {
        days.enumerated()
            .filter { scope < 0 || $0.offset == scope }
            .map { Entry(index: $0.offset, day: $0.element) }
    }

    private var targetIndex: Int {
        scope >= 0 ? scope : min(max(initialIndex, 0), max(days.count - 1, 0))
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(visible) { entry in
                        let stops = entry.day.sortedStops
                        let anchor = trip.window(for: entry.day.date).anchor
                        if let anchor {
                            Annotation("Hotel", coordinate: anchor) {
                                HotelPin()
                            }
                        }
                        ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { number, stop in
                            Annotation(stop.name, coordinate: stop.coordinate) {
                                StopPin(number: number + 1,
                                        category: stop.category,
                                        isDone: stop.isDone,
                                        dayIndex: entry.index)
                                    .onTapGesture { selected = stop }
                            }
                        }
                        let path = (anchor.map { [$0] } ?? []) + stops.map(\.coordinate)
                        if path.count > 1 && !(showTransit && !segments.isEmpty) {
                            MapPolyline(coordinates: path)
                                .stroke(DayPalette.color(entry.index).opacity(0.7), lineWidth: 3)
                        }
                    }
                    if showTransit {
                        RouteDrawing.lines(segments)
                    }
                    if let pending {
                        Marker(pending.name, systemImage: "mappin", coordinate: pending.coordinate)
                            .tint(Theme.danger)
                    }
                }
                .mapControls {
                    MapCompass()
                    MapUserLocationButton()
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    guard dropMode, let coordinate = proxy.convert(point, from: .local) else { return }
                    Task { await drop(at: coordinate) }
                }
            }
            .overlay(alignment: .top) {
                if dropMode {
                    Label("Tap the map to drop a pin", systemImage: "hand.tap")
                        .font(Typography.label)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 44)
                        .floatingChrome()
                        .padding(.top, Spacing.s)
                }
            }
            .navigationTitle(scope < 0 ? "All days" : "Day \(scope + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Show", selection: $scope) {
                            Text("All days").tag(-1)
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                Text("Day \(index + 1) · \(Format.dayChip(day.date))").tag(index)
                            }
                        }
                    } label: {
                        Label("Show", systemImage: "calendar")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Toggle(isOn: $dropMode) {
                        Label("Drop pin", systemImage: "mappin.and.ellipse")
                    }
                    .toggleStyle(.button)
                    Spacer()
                    Toggle(isOn: $showTransit) {
                        Label("Transit lines", systemImage: "tram.fill")
                    }
                    .toggleStyle(.button)
                }
            }
            .onAppear {
                scope = initialIndex < days.count ? initialIndex : -1
                showTransit = trip.transport == .transit
            }
            .task(id: transitKey) { await loadTransit() }
            .onChange(of: scope) { camera = .automatic }
            .sheet(item: $pending) { pin in
                PinSheet(pin: pin, days: days, defaultIndex: targetIndex) { name, dayIndex in
                    add(pin, name: name, dayIndex: dayIndex)
                }
            }
            .sheet(item: $selected) { stop in
                StopDetailView(stop: stop)
            }
        }
    }

    /// Changes when the lines have to be drawn again: toggle, shown days, or the stops of those days.
    private var transitKey: String {
        guard showTransit else { return "off" }
        let stops = visible.map { entry in
            entry.day.sortedStops.map { "\($0.persistentModelID.hashValue)@\($0.plannedTime?.timeIntervalSince1970 ?? 0)" }
                .joined(separator: ",")
        }
        return "on|\(scope)|" + stops.joined(separator: ";")
    }

    /// Public transport lines between the stops of the shown days, one leg after the other (the
    /// routes are cached, so a second look costs no requests).
    private func loadTransit() async {
        guard showTransit else {
            segments = []
            return
        }
        let zone = await TripTimeZone.ensure(trip)
        var collected: [RouteSegment] = []
        segments = []

        for entry in visible {
            let day = entry.day
            var previous: (coordinate: CLLocationCoordinate2D, clock: Date, fromHotel: Bool)?
            if let anchor = trip.window(for: day.date).anchor {
                previous = (anchor, day.defaultWallClock(hour: 9), true)
            }
            for (number, stop) in day.sortedStops.enumerated() {
                if let origin = previous {
                    // The same times the Plan list uses, so both ask for the same routes and share the saved answers.
                    var timing: TransitTiming = .departAt(origin.clock)
                    if origin.fromHotel, let planned = stop.plannedTime {
                        timing = .arriveBy(day.combine(time: planned))
                    }
                    let outcome = await TransitRouter.lookup(from: origin.coordinate, to: stop.coordinate,
                                                             timing: timing, timeZone: zone)
                    if Task.isCancelled { return }
                    if case .routes(let result) = outcome, let best = result.best {
                        collected += TransitPaths.segments(from: best, prefix: "\(entry.index)-\(number)")
                        segments = collected
                    }
                }
                var leaves = day.defaultWallClock(hour: 10)
                if let planned = stop.plannedTime {
                    leaves = day.combine(time: planned).addingTimeInterval(TimeInterval(stop.durationMinutes * 60))
                }
                previous = (stop.coordinate, leaves, false)
            }
        }
    }

    private func drop(at coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var name = "Dropped pin"
        var address = ""
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            name = placemark.areasOfInterest?.first ?? placemark.name ?? name
            address = [placemark.thoroughfare, placemark.locality].compactMap { $0 }.joined(separator: ", ")
        }
        pending = PendingPin(coordinate: coordinate, name: name, address: address)
        dropMode = false
    }

    private func add(_ pin: PendingPin, name: String, dayIndex: Int) {
        guard days.indices.contains(dayIndex) else { return }
        let stop = Stop(name: name.isEmpty ? "Dropped pin" : name,
                        latitude: pin.coordinate.latitude,
                        longitude: pin.coordinate.longitude,
                        address: pin.address,
                        category: .other)
        days[dayIndex].append(stop)
    }

    private struct PinSheet: View {
        let pin: PendingPin
        let days: [Day]
        let defaultIndex: Int
        let onAdd: (String, Int) -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var name = ""
        @State private var dayIndex = 0

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Group {
                            TextField("Name", text: $name)
                            if !pin.address.isEmpty {
                                Label(pin.address, systemImage: "mappin.and.ellipse")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                    Section {
                        Group {
                            Picker("Add to", selection: $dayIndex) {
                                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                    Text("Day \(index + 1) · \(Format.dayChip(day.date))").tag(index)
                                }
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .navigationTitle("Add this spot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onAdd(name, dayIndex)
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    name = pin.name
                    dayIndex = defaultIndex
                }
            }
            .presentationDetents([.medium])
        }
    }
}
