import SwiftUI

/// Sets a time for every stop of a day: from a start time, one after another, using each stop's
/// stay length plus the estimated travel time between stops.
struct AutoTimeSheet: View {
    @Bindable var day: Day

    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    private var stops: [Stop] { day.sortedStops }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("First stop at", selection: $start, displayedComponents: .hourAndMinute)
                } footer: {
                    Text("Each stop starts after the previous one ends, plus travel time (walking, or driving for longer hops) and 5 minutes of slack. This replaces existing times for this day.")
                }

                Section("Preview") {
                    let times = schedule()
                    ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                        HStack {
                            Text(Format.time(times[index]))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(stop.name)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Set times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let times = schedule()
                        for (stop, time) in zip(stops, times) {
                            stop.plannedTime = time
                        }
                        dismiss()
                    }
                    .disabled(stops.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func schedule() -> [Date] {
        let items = stops.enumerated().map { index, stop -> ScheduleService.AutoItem in
            var travel = 0
            if index > 0 {
                let previous = stops[index - 1]
                let meters = RoutingService.straightLine(from: previous.coordinate, to: stop.coordinate)
                let mode: TravelMode = meters > 2_500 ? .drive : .walk
                travel = Int((RoutingService.estimate(from: previous.coordinate, to: stop.coordinate, mode: mode) / 60).rounded(.up))
            }
            return ScheduleService.AutoItem(durationMinutes: stop.durationMinutes, travelMinutes: travel)
        }
        return ScheduleService.autoSchedule(items: items, start: day.combine(time: start))
    }
}
