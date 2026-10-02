import SwiftUI
import SwiftData

struct PlannerView: View {
    @Bindable var trip: Trip

    @State private var selectedIndex = 0
    @State private var showAddPlace = false
    @State private var editingStop: Stop?

    private var days: [Day] { trip.sortedDays }

    private var selectedDay: Day? {
        days.indices.contains(selectedIndex) ? days[selectedIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            dayPicker

            if let day = selectedDay {
                StopsMapView(stops: day.sortedStops)
                    .id(day.persistentModelID)
                    .frame(height: 240)

                WeatherChip(date: day.date,
                            coordinate: day.sortedStops.first?.coordinate ?? trip.anyCoordinate,
                            outdoorStops: day.stops.filter { $0.category.isOutdoor }.count)
                    .padding(.horizontal)
                    .padding(.top, 8)

                DayStopListView(day: day) { editingStop = $0 }
            } else {
                ContentUnavailableView("No days", systemImage: "calendar",
                                       description: Text("Edit the trip dates to add days."))
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                NavigationLink {
                    TodayView(trip: trip)
                } label: {
                    Label("Trip Mode", systemImage: "location.fill")
                }
                Button("Add place", systemImage: "plus") { showAddPlace = true }
                    .disabled(selectedDay == nil)
            }
        }
        .sheet(isPresented: $showAddPlace) {
            if let day = selectedDay {
                AddPlaceView(day: day)
            }
        }
        .sheet(item: $editingStop) { stop in
            StopDetailView(stop: stop)
        }
        .onAppear(perform: jumpToToday)
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
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(index == selectedIndex ? Color.accentColor : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
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
}
