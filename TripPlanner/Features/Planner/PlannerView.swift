import SwiftUI
import SwiftData

struct PlannerView: View {
    @Bindable var trip: Trip

    @State private var selectedIndex = 0
    @State private var selectedStop: Stop?
    @State private var mapDetent: MapDetent = .half
    @State private var showAddPlace = false
    @State private var showImport = false
    @State private var showAutoPlan = false
    @State private var showSaved = false
    @State private var showExport = false
    @State private var showMap = false
    @State private var showChat = false
    @State private var showTimes = false
    @State private var editingStop: Stop?
    @State private var feedback = 0

    private var days: [Day] { trip.sortedDays }

    private var selectedDay: Day? {
        days.indices.contains(selectedIndex) ? days[selectedIndex] : nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if let day = selectedDay {
                        PlanDayTimeline(trip: trip, day: day, dayIndex: selectedIndex, selected: $selectedStop,
                                        onOpen: { editingStop = $0 },
                                        onAddPlace: { showAddPlace = true })
                            .id(day.persistentModelID)
                    } else {
                        EmptyState(title: "No days", systemImage: "calendar",
                                   message: "Edit the trip dates to add days.")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    topPanel(availableHeight: geometry.size.height)
                }
                // Tapping a pin brings its card into view; tapping a card highlights its pin.
                .onChange(of: selectedStop?.persistentModelID) { _, id in
                    guard let id else { return }
                    Motion.perform { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .accessibilityLabel("Ask the AI to change the plan")
                actionsMenu
            }
        }
        .sheet(isPresented: $showAddPlace) {
            if let day = selectedDay {
                AddPlaceView(day: day)
            }
        }
        .sheet(isPresented: $showChat) {
            PlanChatView(trip: trip)
        }
        .sheet(isPresented: $showImport) {
            ImportFlowView(trip: trip)
        }
        .sheet(isPresented: $showAutoPlan) {
            AutoPlanFlowView(trip: trip)
        }
        .sheet(isPresented: $showSaved) {
            SavedPlacesView(trip: trip)
        }
        .sheet(isPresented: $showExport) {
            ExportView(trip: trip)
        }
        .sheet(isPresented: $showTimes) {
            if let day = selectedDay {
                AutoTimeSheet(day: day)
            }
        }
        .fullScreenCover(isPresented: $showMap) {
            DayMapView(trip: trip, initialIndex: selectedIndex)
        }
        .sheet(item: $editingStop) { stop in
            StopDetailView(stop: stop)
        }
        .sensoryFeedback(.success, trigger: feedback)
        .onChange(of: selectedIndex) { _, _ in selectedStop = nil }
        .onAppear(perform: jumpToToday)
    }

    /// The sticky part: the day strip and, under it, the map that can be dragged between three heights.
    @ViewBuilder
    private func topPanel(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            DayStrip(days: days, selectedIndex: $selectedIndex)

            if let day = selectedDay {
                let window = trip.window(for: day.date)
                DetentMapPanel(detent: $mapDetent, availableHeight: availableHeight) {
                    StopsMapView(stops: day.sortedStops,
                                 highlighted: selectedStop,
                                 dayIndex: selectedIndex,
                                 onSelect: { selectedStop = $0 },
                                 recenterOnHighlight: true,
                                 start: window.anchor,
                                 startName: window.anchorName)
                        .id(day.persistentModelID)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                showMap = true
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 44, height: 44)
                                    .floatingChrome(in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(Spacing.s)
                            .accessibilityLabel("Open full-screen map")
                        }
                }
            }
        }
        .background(Theme.background)
    }

    /// Add places, Auto plan, import, and the actions for the selected day.
    private var actionsMenu: some View {
        Menu {
            Section("Add") {
                Button("Add place", systemImage: "mappin.and.ellipse") { showAddPlace = true }
                    .disabled(selectedDay == nil)
                Button("Auto plan…", systemImage: "wand.and.stars") { showAutoPlan = true }
                Button("Ask the AI to change the plan…", systemImage: "bubble.left.and.text.bubble.right") { showChat = true }
                Button("Import program (PDF, Word, photo)", systemImage: "doc.viewfinder") { showImport = true }
                Button("Saved places (\(trip.savedPlaces.count))", systemImage: "bookmark") { showSaved = true }
            }
            Section("This day") {
                Button("Optimize route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    if let day = selectedDay { optimize(day) }
                }
                .disabled((selectedDay?.stops.count ?? 0) < 2)
                Button("Sort by time", systemImage: "clock.arrow.2.circlepath") {
                    if let day = selectedDay { sortByTime(day) }
                }
                .disabled((selectedDay?.stops.count ?? 0) < 2)
                Button("Adjust times…", systemImage: "clock.badge.checkmark") { showTimes = true }
                    .disabled((selectedDay?.stops.count ?? 0) < 1)
                Menu("Copy day to…", systemImage: "doc.on.doc") {
                    ForEach(Array(days.enumerated()), id: \.element.persistentModelID) { index, target in
                        if target.persistentModelID != selectedDay?.persistentModelID {
                            Button("Day \(index + 1) · \(Format.dayChip(target.date))") {
                                selectedDay?.copyStops(to: target)
                                feedback += 1
                            }
                        }
                    }
                }
                .disabled((selectedDay?.stops.count ?? 0) < 1 || days.count < 2)
            }
            Section {
                Button("Share & export", systemImage: "square.and.arrow.up") { showExport = true }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
        .accessibilityLabel("Plan actions")
    }

    private func jumpToToday() {
        if let today = days.firstIndex(where: { Calendar.current.isDateInToday($0.date) }) {
            selectedIndex = today
        }
    }

    /// Shortest walking order. With a hotel the route starts from it, otherwise the first stop stays first.
    private func optimize(_ day: Day) {
        let stops = day.sortedStops
        guard stops.count > 2 || (trip.hotelCoordinate(on: day.date) != nil && stops.count > 1) else { return }
        let coordinates = stops.map(\.coordinate)
        if let hotel = trip.hotelCoordinate(on: day.date) {
            let order = RouteOptimizer.order([hotel] + coordinates).dropFirst().map { $0 - 1 }
            day.renumber(order.map { stops[$0] })
        } else {
            day.renumber(RouteOptimizer.order(coordinates).map { stops[$0] })
        }
        feedback += 1
    }

    private func sortByTime(_ day: Day) {
        day.sortByTime()
        feedback += 1
    }
}
