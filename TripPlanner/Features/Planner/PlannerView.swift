import SwiftUI
import SwiftData

struct PlannerView: View {
    @Bindable var trip: Trip

    @State private var selectedIndex = 0
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
    @State private var editMode: EditMode = .inactive

    private var days: [Day] { trip.sortedDays }

    private var selectedDay: Day? {
        days.indices.contains(selectedIndex) ? days[selectedIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            dayPicker

            if let day = selectedDay {
                let window = trip.window(for: day.date)
                StopsMapView(stops: day.sortedStops, dayIndex: selectedIndex, start: window.anchor, startName: window.anchorName)
                    .id(day.persistentModelID)
                    .frame(height: 220)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showMap = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.bold())
                                .padding(9)
                                .background(.thinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Open full-screen map")
                    }

                WeatherChip(date: day.date,
                            coordinate: day.sortedStops.first?.coordinate ?? trip.anyCoordinate,
                            outdoorStops: day.stops.filter { $0.category.isOutdoor }.count)
                    .padding(.horizontal)
                    .padding(.top, 8)

                DayAlertsView(trip: trip, day: day)
                    .padding(.horizontal)
                    .padding(.top, 4)

                DayStopListView(day: day) { editingStop = $0 }
                    .id(day.persistentModelID)
            } else {
                ContentUnavailableView("No days", systemImage: "calendar",
                                       description: Text("Edit the trip dates to add days."))
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            TabHeader(title: trip.name) {
                if editMode.isEditing {
                    Button("Adjust times") { showTimes = true }
                        .font(.body)
                        .disabled((selectedDay?.stops.count ?? 0) < 1)
                }
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.body)
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .accessibilityLabel("Ask the AI to change the plan")
                actionsMenu
            }
        }
        .environment(\.editMode, $editMode)
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
        .onAppear(perform: jumpToToday)
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

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.element.persistentModelID) { index, day in
                    Button {
                        selectedIndex = index
                    } label: {
                        VStack(spacing: 2) {
                            Text("Day \(index + 1)")
                                .font(.caption.bold())
                            Text(Format.dayChip(day.date))
                                .font(.caption)
                            Circle()
                                .fill(day.stops.isEmpty ? Color.clear : (index == selectedIndex ? Color.white : Color.accentColor))
                                .frame(width: 5, height: 5)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(index == selectedIndex ? Color.accentColor : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Day \(index + 1), \(day.stops.count) stops")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
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
