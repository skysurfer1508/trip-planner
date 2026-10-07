import SwiftUI
import MapKit

/// Walk through the planned trip one day at a time. Change a day by tapping a stop, using a quick
/// action, or by telling the AI what you want ("more food", "swap the museum for something
/// outdoors", "start later"). Only real places from the plan's pool can be used.
struct PlanWalkthroughView: View {
    let trip: Trip
    @Binding var plan: [PlannedDay]
    let pool: [PlanCandidate]
    let prefs: TripPreferences
    let windows: [DayWindow]
    let onDone: () -> Void

    @Environment(Secrets.self) private var secrets

    private struct Reply {
        var text: String
        var isError = false
    }

    private struct AlternativeTarget: Identifiable {
        let id = UUID()
        let stop: PlannedStop
    }

    private static let suggestions = [
        "Add more food", "Less walking", "Swap the museum for something outdoors", "Add a café break",
        "Make it more relaxed", "Add something for kids", "No nightlife", "Start later",
    ]

    @State private var dayIndex = 0
    @State private var history: [[PlannedDay]] = []
    @State private var prompt = ""
    @State private var busy = false
    @State private var reply: Reply?
    @State private var alternatives: AlternativeTarget?

    private var engine: (any AIEngine)? { AIRouter.current(geminiKey: secrets.keys.gemini) }
    private var tripDays: [Day] { trip.sortedDays }

    private func window(_ index: Int) -> DayWindow {
        windows.indices.contains(index) ? windows[index] : DayWindow()
    }

    private func usedElsewhere(_ index: Int) -> Set<String> {
        var ids = Set<String>()
        for (other, day) in plan.enumerated() where other != index {
            for stop in day.stops { ids.insert(stop.candidate.id) }
        }
        return ids
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader

            TabView(selection: $dayIndex) {
                ForEach(plan.indices, id: \.self) { index in
                    dayPage(index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Walk through")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .sheet(item: $alternatives) { target in
            AlternativesSheet(stop: target.stop,
                              options: PlanEditor.alternatives(for: target.stop, pool: pool,
                                                               taken: usedElsewhere(dayIndex)
                                                                   .union(plan[dayIndex].stops.map { $0.candidate.id }),
                                                               prefs: prefs)) { chosen in
                applyEdits([.replace(target.stop.candidate.id, with: chosen.id)],
                           message: "Replaced \(target.stop.candidate.name) with \(chosen.name).")
            }
        }
    }

    // MARK: Header

    private var dayHeader: some View {
        HStack {
            Button {
                withAnimation { dayIndex = max(dayIndex - 1, 0) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(dayIndex == 0)
            .accessibilityLabel("Previous day")

            Spacer()
            VStack(spacing: 2) {
                Text("Day \(dayIndex + 1) of \(plan.count)")
                    .font(.headline)
                if tripDays.indices.contains(dayIndex) {
                    Text(tripDays[dayIndex].date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Button {
                withAnimation { dayIndex = min(dayIndex + 1, plan.count - 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(dayIndex >= plan.count - 1)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: One day

    private func dayPage(_ index: Int) -> some View {
        let day = plan[index]
        let dayWindow = window(index)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.theme)
                        .font(.title2.bold())
                    Spacer()
                    Menu {
                        Button("Shuffle this day", systemImage: "shuffle") { shuffle(index) }
                        Button("Start 1 hour earlier", systemImage: "sunrise") { shift(index, by: -60) }
                        Button("Start 1 hour later", systemImage: "sunset") { shift(index, by: 60) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Day actions")
                }

                if let note = windowNote(dayWindow) {
                    Label(note, systemImage: "airplane")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                PlanMapView(stops: day.stops, start: dayWindow.anchor, startName: dayWindow.anchorName)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if day.stops.isEmpty {
                    Text("Nothing planned for this day. Ask for something below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        if let anchor = dayWindow.anchor, let first = day.stops.first {
                            startRow(name: dayWindow.anchorName ?? "Hotel", from: anchor, to: first.candidate.coordinate)
                            Divider()
                        }
                        ForEach(Array(day.stops.enumerated()), id: \.element.candidate.id) { number, stop in
                            stopRow(stop, number: number + 1)
                            if number < day.stops.count - 1 { Divider() }
                        }
                    }
                    .card()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private func windowNote(_ window: DayWindow) -> String? {
        var parts: [String] = []
        if let start = window.startMinute { parts.append("Starts at \(TripLogistics.timeText(start)) after you land.") }
        if let end = window.endMinute { parts.append("Ends by \(TripLogistics.timeText(end)) for your flight.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func startRow(name: String, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> some View {
        let distance = RoutingService.straightLine(from: from, to: to)
        let mode: TravelMode = distance > 2_500 ? .drive : .walk
        return HStack(spacing: 12) {
            HotelPin()
            VStack(alignment: .leading, spacing: 2) {
                Text("Start from \(name)")
                    .font(.subheadline.weight(.medium))
                Label("\(Format.duration(RoutingService.estimate(from: from, to: to, mode: mode))) to the first stop",
                      systemImage: mode.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func stopRow(_ stop: PlannedStop, number: Int) -> some View {
        HStack(spacing: 12) {
            StopPin(number: number, category: stop.candidate.kind.stopCategory)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.candidate.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(TripLogistics.timeText(stop.startMinute))
                        .monospacedDigit()
                    Text("·")
                    Text(Format.minutes(stop.durationMinutes))
                    Text("·")
                    Text(stop.candidate.kind.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Replace…", systemImage: "arrow.triangle.2.circlepath") {
                    alternatives = AlternativeTarget(stop: stop)
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    applyEdits([.remove(stop.candidate.id)], message: "Removed \(stop.candidate.name).")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(stop.candidate.name)")
        }
        .padding(.vertical, 8)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: reply.isError ? "exclamationmark.triangle.fill" : "wand.and.stars")
                        .foregroundStyle(reply.isError ? Color.orange : Color.accentColor)
                    Text(reply.text)
                        .font(.footnote)
                    Spacer(minLength: 4)
                    if !history.isEmpty {
                        Button("Undo") { undo() }
                            .font(.footnote.bold())
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            prompt = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(engine == nil ? "Turn on an AI engine in Settings to type changes"
                                        : "Tell the AI what to change on day \(dayIndex + 1)…",
                          text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .disabled(engine == nil || busy)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }

                if busy {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(engine == nil || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !text.isEmpty, !busy, plan.indices.contains(dayIndex) else { return }
        busy = true
        defer { busy = false }

        let index = dayIndex
        let prepared = DayEditService.prepare(instruction: text,
                                              day: plan[index],
                                              dayNumber: index + 1,
                                              pool: pool,
                                              usedElsewhere: usedElsewhere(index),
                                              prefs: prefs,
                                              destination: trip.destination,
                                              window: window(index))
        do {
            let response = try await engine.editDay(prepared.request)
            let edits = DayEditService.edits(from: response, prepared: prepared)
            prompt = ""
            if edits.isEmpty {
                reply = Reply(text: response.summary.isEmpty
                              ? "I couldn't find a way to do that with the places available."
                              : response.summary)
                return
            }
            applyEdits(edits, message: response.summary, on: index)
        } catch {
            reply = Reply(text: error.localizedDescription, isError: true)
        }
    }

    private func applyEdits(_ edits: [PlanEdit], message: String, on index: Int? = nil) {
        let target = index ?? dayIndex
        guard plan.indices.contains(target) else { return }
        let outcome = PlanEditor.apply(edits,
                                       to: plan[target],
                                       pool: pool,
                                       usedElsewhere: usedElsewhere(target),
                                       prefs: prefs,
                                       window: window(target))
        guard outcome.changed else {
            reply = Reply(text: outcome.notes.first ?? "Nothing changed.", isError: true)
            return
        }
        history.append(plan)
        plan[target] = outcome.day
        let notes = outcome.notes.joined(separator: " ")
        reply = Reply(text: [message, notes].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func shuffle(_ index: Int) {
        guard plan.indices.contains(index) else { return }
        let center = tripDays.indices.contains(index) ? (trip.destinationCoordinate ?? window(index).anchor) : nil
        guard let center = center ?? trip.anyCoordinate else { return }
        var generator = SystemRandomNumberGenerator()
        let fresh = PlanEditor.shuffle(plan[index],
                                       pool: pool,
                                       usedElsewhere: usedElsewhere(index),
                                       prefs: prefs,
                                       window: window(index),
                                       center: center,
                                       using: &generator)
        history.append(plan)
        plan[index] = fresh
        reply = Reply(text: "Here's another version of day \(index + 1).")
    }

    private func shift(_ index: Int, by minutes: Int) {
        guard plan.indices.contains(index) else { return }
        let outcome = PlanEditor.shiftStart(plan[index], by: minutes, prefs: prefs, window: window(index))
        history.append(plan)
        plan[index] = outcome.day
        reply = Reply(text: minutes < 0 ? "Day \(index + 1) now starts earlier." : "Day \(index + 1) now starts later.")
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        plan = previous
        reply = Reply(text: "Undone.")
    }
}

/// The places that could take a stop's place.
private struct AlternativesSheet: View {
    let stop: PlannedStop
    let options: [PlanCandidate]
    let onPick: (PlanCandidate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    onPick(option)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.kind.symbol)
                            .frame(width: 30)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                                .foregroundStyle(.primary)
                            Text("\(option.kind.title) · \(Format.distance(RoutingService.straightLine(from: stop.candidate.coordinate, to: option.coordinate))) from \(stop.candidate.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if options.isEmpty {
                    ContentUnavailableView("No other options", systemImage: "binoculars",
                                           description: Text("There are no unused places of this kind nearby."))
                }
            }
            .navigationTitle("Replace \(stop.candidate.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Map of a planned day: numbered stops, the hotel and the route.
struct PlanMapView: View {
    let stops: [PlannedStop]
    var start: CLLocationCoordinate2D?
    var startName: String?

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            if let start {
                Annotation(startName ?? "Hotel", coordinate: start) {
                    HotelPin()
                }
            }
            ForEach(Array(stops.enumerated()), id: \.element.candidate.id) { index, stop in
                Annotation(stop.candidate.name, coordinate: stop.candidate.coordinate) {
                    StopPin(number: index + 1, category: stop.candidate.kind.stopCategory)
                }
            }
            let path = (start.map { [$0] } ?? []) + stops.map { $0.candidate.coordinate }
            if path.count > 1 {
                MapPolyline(coordinates: path)
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 3)
            }
        }
        .id(stops.map { $0.candidate.id }.joined(separator: ","))
        .mapControls {
            MapCompass()
        }
    }
}
