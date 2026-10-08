import SwiftUI
import MapKit

/// Walk through the planned trip one day at a time. Change a day by tapping a stop, using a quick
/// action, or by telling the AI what you want ("more food", "swap the museum for something
/// outdoors", "start later"). Only real places from the plan's pool can be used.
struct PlanWalkthroughView: View {
    let trip: Trip
    @Binding var plan: [PlannedDay]
    @Binding var pool: [PlanCandidate]
    /// The traveller's own places that did not fit on any day.
    @Binding var leftOut: [PlanCandidate]
    let prefs: TripPreferences
    let windows: [DayWindow]
    /// Real public transport minutes found while planning, used when a day is scheduled again.
    var transitMinutes: [String: Int] = [:]
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
    private struct Snapshot {
        var plan: [PlannedDay]
        var leftOut: [PlanCandidate]
    }

    @State private var history: [Snapshot] = []
    @State private var prompt = ""
    @State private var busy = false
    @State private var reply: Reply?
    @State private var alternatives: AlternativeTarget?
    @State private var showAddPlace = false

    private var engine: (any AIEngine)? { AIRouter.current(geminiKey: secrets.keys.gemini) }
    private var tripDays: [Day] { trip.sortedDays }

    private var travelOverride: TravelOverride? {
        let known = transitMinutes
        return known.isEmpty ? nil : { a, b in known[TransitRouter.pairKey(a, b)] }
    }

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
        .sheet(isPresented: $showAddPlace) {
            PlacePickerView(query: "", region: trip.searchRegion) { item in
                addPicked(item)
            }
        }
        .sheet(item: $alternatives) { target in
            AlternativesSheet(stop: target.stop,
                              region: trip.searchRegion,
                              onSearchPick: { item in
                                  let candidate = PlanCandidate(picked: item)
                                  if !pool.contains(where: { $0.id == candidate.id }) { pool.append(candidate) }
                                  applyEdits([.replace(target.stop.candidate.id, with: candidate.id)],
                                             message: "Replaced \(target.stop.candidate.name) with \(candidate.name).")
                              },
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
                        Divider()
                        Button("Remove nightlife from this day", systemImage: "moon.zzz") { removeNightlife(from: [index]) }
                            .disabled(!hasNightlife(index))
                        Button("Remove nightlife from every day", systemImage: "moon.zzz.fill") {
                            removeNightlife(from: Array(plan.indices))
                        }
                        .disabled(!plan.indices.contains { hasNightlife($0) })
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
                            startRow(name: dayWindow.anchorName ?? "Hotel", from: anchor, first: first, dayIndex: index)
                            Divider()
                        }
                        ForEach(Array(day.stops.enumerated()), id: \.element.candidate.id) { number, stop in
                            stopRow(stop, number: number + 1)
                            if number < day.stops.count - 1 {
                                let next = day.stops[number + 1]
                                TravelLegView(trip: trip, fromName: stop.candidate.name, toName: next.candidate.name,
                                              from: stop.candidate.coordinate, to: next.candidate.coordinate,
                                              departAt: wallClock(index, minute: stop.startMinute + stop.durationMinutes),
                                              arriveBy: nil, inset: 36)
                                    .padding(.bottom, 8)
                                Divider()
                            }
                        }
                    }
                    .card()
                }

                if !leftOut.isEmpty {
                    leftOutCard(for: index)
                }

                Button {
                    dayIndex = index
                    showAddPlace = true
                } label: {
                    Label("Add a place to day \(index + 1)", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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

    /// The day's time on the clock at the destination, for timetable lookups.
    private func wallClock(_ dayIndex: Int, minute: Int) -> Date? {
        guard tripDays.indices.contains(dayIndex) else { return nil }
        return Calendar.current.date(bySettingHour: min(minute / 60, 23), minute: minute % 60, second: 0,
                                     of: tripDays[dayIndex].date)
    }

    private func startRow(name: String, from: CLLocationCoordinate2D, first: PlannedStop, dayIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                HotelPin()
                Text("Start from \(name)")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            TravelLegView(trip: trip, fromName: name, toName: first.candidate.name,
                          from: from, to: first.candidate.coordinate,
                          departAt: nil,
                          arriveBy: wallClock(dayIndex, minute: first.startMinute),
                          suffix: "to the first stop", inset: 36)
        }
        .padding(.vertical, 8)
    }

    private func stopRow(_ stop: PlannedStop, number: Int) -> some View {
        let candidate = stop.candidate
        let category = candidate.kind.stopCategory
        return HStack(alignment: .top, spacing: 12) {
            StopPin(number: number, category: category)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(TripLogistics.timeText(stop.startMinute))
                        .monospacedDigit()
                    Text("·")
                    Text(Format.minutes(stop.durationMinutes))
                    Text("·")
                    Text(candidate.kind.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if candidate.isMustSee, let wanted = candidate.preferredMinute {
                    Label(candidate.timeIsSuggested
                          ? "Best around \(TripLogistics.timeText(wanted))"
                          : "You asked for around \(TripLogistics.timeText(wanted))", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                PlaceSummaryText(name: candidate.name, coordinate: candidate.coordinate)
            }
            Spacer(minLength: 4)
            PlaceThumbnail(name: candidate.name, coordinate: candidate.coordinate, category: category, size: 56)
            Menu {
                Button("Replace…", systemImage: "arrow.triangle.2.circlepath") {
                    alternatives = AlternativeTarget(stop: stop)
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    applyEdits([.remove(candidate.id)], message: "Removed \(candidate.name).")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(candidate.name)")
        }
        .padding(.vertical, 8)
        .loadsPlacePreview(name: candidate.name, coordinate: candidate.coordinate, category: category)
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
                                       window: window(target),
                                       travelOverride: travelOverride)
        guard outcome.changed else {
            reply = Reply(text: outcome.notes.first ?? "Nothing changed.", isError: true)
            return
        }
        remember()
        let removedOnPurpose: Set<String> = Set(edits.compactMap { edit in
            switch edit {
            case .remove(let id): id
            case .replace(let id, _): id
            default: nil
            }
        })
        noteLost(from: plan[target], to: outcome.day, except: removedOnPurpose)
        plan[target] = outcome.day
        let notes = outcome.notes.joined(separator: " ")
        reply = Reply(text: [message, notes].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// A place found by searching: it joins the pool and is scheduled into the current day.
    private func addPicked(_ item: MKMapItem) {
        let candidate = PlanCandidate(picked: item)
        if !pool.contains(where: { $0.id == candidate.id }) {
            pool.append(candidate)
        }
        applyEdits([.add(candidate.id, after: nil)], message: "Added \(candidate.name) to day \(dayIndex + 1).")
    }

    /// Places from the traveller's list that are not on any day yet, each with a button to add it here.
    private func leftOutCard(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your places that aren't in the plan yet", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(leftOut) { place in
                HStack {
                    Text(place.name)
                        .font(.subheadline)
                    Spacer()
                    Button("Add to day \(index + 1)") {
                        addLeftOut(place, to: index)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func addLeftOut(_ place: PlanCandidate, to index: Int) {
        applyEdits([.add(place.id, after: nil)], message: "Added \(place.name) to day \(index + 1).", on: index)
        if plan.indices.contains(index), plan[index].stops.contains(where: { $0.candidate.id == place.id }) {
            leftOut.removeAll { $0.id == place.id }
        }
    }

    private func hasNightlife(_ index: Int) -> Bool {
        plan.indices.contains(index) && plan[index].stops.contains { $0.slot == .nightlife || $0.candidate.kind == .nightlife }
    }

    /// Takes the bars and clubs out of some days; the rest of each day is scheduled again.
    private func removeNightlife(from days: [Int]) {
        var updated = plan
        var removed = 0
        for index in days where plan.indices.contains(index) {
            let ids = plan[index].stops
                .filter { $0.slot == .nightlife || $0.candidate.kind == .nightlife }
                .map { $0.candidate.id }
            guard !ids.isEmpty else { continue }
            let outcome = PlanEditor.apply(ids.map { .remove($0) },
                                           to: plan[index],
                                           pool: pool,
                                           usedElsewhere: usedElsewhere(index),
                                           prefs: prefs,
                                           window: window(index),
                                           travelOverride: travelOverride)
            noteLost(from: plan[index], to: outcome.day, except: Set(ids))
            updated[index] = outcome.day
            removed += ids.count
        }
        guard removed > 0 else { return }
        remember()
        plan = updated
        reply = Reply(text: "Removed \(removed) nightlife \(removed == 1 ? "stop" : "stops").")
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
        remember()
        noteLost(from: plan[index], to: fresh)
        plan[index] = fresh
        reply = Reply(text: "Here's another version of day \(index + 1).")
    }

    private func shift(_ index: Int, by minutes: Int) {
        guard plan.indices.contains(index) else { return }
        let outcome = PlanEditor.shiftStart(plan[index], by: minutes, prefs: prefs, window: window(index),
                                            travelOverride: travelOverride)
        remember()
        noteLost(from: plan[index], to: outcome.day)
        plan[index] = outcome.day
        reply = Reply(text: minutes < 0 ? "Day \(index + 1) now starts earlier." : "Day \(index + 1) now starts later.")
    }

    private func remember() {
        history.append(Snapshot(plan: plan, leftOut: leftOut))
    }

    /// A place of the traveller's that a change pushed out of the day (it no longer fit) goes to the
    /// "not in the plan yet" list instead of vanishing. Places removed on purpose don't.
    private func noteLost(from old: PlannedDay, to new: PlannedDay, except purposely: Set<String> = []) {
        let kept = Set(new.stops.map { $0.candidate.id })
        for stop in old.stops where stop.candidate.isMustSee
            && !kept.contains(stop.candidate.id) && !purposely.contains(stop.candidate.id)
            && !leftOut.contains(where: { $0.id == stop.candidate.id }) {
            leftOut.append(stop.candidate)
        }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        plan = previous.plan
        leftOut = previous.leftOut
        reply = Reply(text: "Undone.")
    }
}

/// The places that could take a stop's place.
private struct AlternativesSheet: View {
    let stop: PlannedStop
    let region: MKCoordinateRegion?
    /// A place found with the search instead of the list.
    let onSearchPick: (MKMapItem) -> Void
    let options: [PlanCandidate]
    let onPick: (PlanCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    onPick(option)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        PlaceThumbnail(name: option.name, coordinate: option.coordinate,
                                       category: option.kind.stopCategory, size: 44, corner: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                                .foregroundStyle(.primary)
                            Text("\(option.kind.title) · \(Format.distance(RoutingService.straightLine(from: stop.candidate.coordinate, to: option.coordinate))) from \(stop.candidate.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            PlaceSummaryText(name: option.name, coordinate: option.coordinate, lines: 2)
                        }
                    }
                    .loadsPlacePreview(name: option.name, coordinate: option.coordinate,
                                       category: option.kind.stopCategory)
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Search", systemImage: "magnifyingglass") { showSearch = true }
                }
            }
            .sheet(isPresented: $showSearch) {
                PlacePickerView(query: "", region: region) { item in
                    onSearchPick(item)
                    dismiss()
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
