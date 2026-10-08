import SwiftUI
import CoreLocation

/// Sets a time for every stop of a day: from a start time, one after another, using each stop's
/// stay length plus the estimated travel time between stops.
struct AutoTimeSheet: View {
    @Bindable var day: Day

    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var windowNote: String?
    /// Real public transport minutes per pair of places, when the trip uses public transport.
    @State private var transitMinutes: [String: Int] = [:]
    @State private var loadingTransit = false

    private var stops: [Stop] { day.sortedStops }

    /// The hotel the day starts from, if there is one.
    private var hotel: CLLocationCoordinate2D? { day.trip?.window(for: day.date).anchor }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(hotel == nil ? "First stop at" : "Leave the hotel at",
                               selection: $start, displayedComponents: .hourAndMinute)
                } footer: {
                    Text("Each stop starts after the previous one ends, plus travel time (\(travelDescription)) and 5 minutes of slack. \(hotel == nil ? "" : "The first stop adds the way from the hotel. ")This replaces existing times for this day.")
                }

                if let windowNote {
                    Section {
                        Label(windowNote, systemImage: "airplane")
                            .font(.footnote)
                    }
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
            .navigationTitle("Adjust times")
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
            .onAppear {
                start = TimeAdjuster.suggestedStart(for: day)
                applyWindow()
            }
            .task(id: transitSignature) {
                // Spinning the time wheel changes the signature many times: wait for it to settle.
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
                await loadTransit()
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// After a flight lands the day can't start at 9:00; start from the time you're ready instead.
    private func applyWindow() {
        guard let window = day.trip?.window(for: day.date) else { return }
        var notes: [String] = []
        if let minute = window.startMinute {
            let ready = minute
            let current = Calendar.current.dateComponents([.hour, .minute], from: start)
            if (current.hour ?? 0) * 60 + (current.minute ?? 0) < ready {
                start = Calendar.current.date(bySettingHour: ready / 60, minute: ready % 60, second: 0, of: start) ?? start
            }
            notes.append("Starts at \(TripLogistics.timeText(ready)), after you land.")
        }
        if let end = window.endMinute {
            notes.append("You have to leave for your flight by \(TripLogistics.timeText(end)).")
        }
        windowNote = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private var usesTransit: Bool { day.trip?.transport == .transit }

    private var travelDescription: String {
        switch day.trip?.transport ?? .walking {
        case .walking: "on foot"
        case .car: "by car"
        case .transit: "real public transport times where available, else an estimate"
        }
    }

    /// Changes when the stops or the start change, so the real durations are looked up again.
    private var transitSignature: String {
        guard usesTransit else { return "off" }
        let ids = stops.map { "\($0.persistentModelID.hashValue)" }.joined(separator: ",")
        let time = Calendar.current.dateComponents([.hour, .minute], from: start)
        return "\(ids)|\(time.hour ?? 0):\(time.minute ?? 0)"
    }

    /// Asks for the public transport time of every leg of the day (saved, so later lookups are free).
    private func loadTransit() async {
        guard usesTransit, let trip = day.trip, TransitRouter.isEnabled else {
            transitMinutes = [:]
            return
        }
        loadingTransit = true
        defer { loadingTransit = false }
        let zone = await TripTimeZone.ensure(trip)
        var table: [String: Int] = [:]
        var previous: CLLocationCoordinate2D? = hotel
        var clock = day.combine(time: start)
        for stop in stops {
            if let origin = previous {
                let outcome = await TransitRouter.lookup(from: origin, to: stop.coordinate,
                                                         timing: .departAt(clock), timeZone: zone)
                if Task.isCancelled { return }
                if let seconds = outcome.bestDuration {
                    table[TransitRouter.pairKey(origin, stop.coordinate)] = Int((seconds / 60).rounded(.up))
                }
            }
            previous = stop.coordinate
            clock = clock.addingTimeInterval(TimeInterval((stop.durationMinutes + 20) * 60))
        }
        transitMinutes = table
    }

    private func schedule() -> [Date] {
        TimeAdjuster.times(stops: stops, start: day.combine(time: start), hotel: hotel,
                           transport: day.trip?.transport ?? .walking, transitMinutes: transitMinutes)
    }
}
