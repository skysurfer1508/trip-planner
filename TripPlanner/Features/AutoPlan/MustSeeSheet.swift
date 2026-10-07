import SwiftUI
import MapKit

/// "Anything you must see?": type what you want ("Belém Tower at sunset on day 2") and the place
/// is searched while you type. A time and a day are optional; without them the planner chooses.
/// Popular sights are listed underneath, so a place can also be added with a single tap.
struct MustSeeSheet: View {
    let destinationName: String
    let center: CLLocationCoordinate2D?
    let region: MKCoordinateRegion?
    let dayCount: Int
    let popular: [MKMapItem]
    let onAdd: (MustSee) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    @State private var text = ""
    @State private var useTime = false
    @State private var time = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var day = 0
    @State private var near: [MKMapItem] = []
    @State private var far: [MKMapItem] = []
    @State private var searching = false
    @State private var searched = false
    @State private var batch: [BatchEntry] = []
    @State private var batchBusy = false
    @State private var batchMessage: String?
    @FocusState private var focused: Bool

    /// One place found in a pasted list.
    private struct BatchEntry: Identifiable {
        let id = UUID()
        var title: String
        var minute: Int?
        var day: Int?
        var item: MKMapItem?
        var include = true
    }

    private var parsed: MustSeeParser.Parsed { MustSeeParser.parse(text) }
    private var query: String { parsed.query }
    /// Several places in one text: they are found together instead of searched as one name.
    private var isList: Bool { MustSeeParser.looksLikeList(text) }

    /// The time chosen by hand, else the one found in the text.
    private var minute: Int? {
        guard useTime else { return parsed.minute }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var dayNumber: Int? {
        if day > 0 { return day }
        guard let found = parsed.day, (1...max(dayCount, 1)).contains(found) else { return nil }
        return found
    }

    var body: some View {
        NavigationStack {
            List {
                promptSection
                whenSection
                resultSections
            }
            .navigationTitle("Must-see")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) { await search() }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    // MARK: Sections

    private var promptSection: some View {
        Section {
            TextField("e.g. Belém Tower at sunset, day 2", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if let understood = understood {
                Label(understood, systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What do you want to see?")
        } footer: {
            Text("Say where and when if you like: \"Colosseum in the evening\", \"Louvre 10:00 on day 3\". Or just type a name. You can also paste a whole list of places.")
        }
    }

    /// What was understood from the text, so mistakes are visible.
    private var understood: String? {
        var parts: [String] = []
        if !useTime, let found = parsed.minute { parts.append("around \(TripLogistics.timeText(found))") }
        if day == 0, let found = parsed.day {
            parts.append(found <= max(dayCount, 1) ? "day \(found)" : "day \(found) (your plan has \(dayCount))")
        }
        return parts.isEmpty ? nil : "Understood: " + parts.joined(separator: ", ")
    }

    private var whenSection: some View {
        Section {
            Toggle("Preferred time", isOn: $useTime.animation())
            if useTime {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                HStack(spacing: 8) {
                    quickTime("Morning", hour: 9, minute: 30)
                    quickTime("Afternoon", hour: 14, minute: 30)
                    quickTime("Evening", hour: 18, minute: 30)
                }
            }
            if dayCount > 1 {
                Picker("Day", selection: $day) {
                    Text("Any day").tag(0)
                    ForEach(1...dayCount, id: \.self) { number in
                        Text("Day \(number)").tag(number)
                    }
                }
            }
        } header: {
            Text("When (optional)")
        } footer: {
            Text("Without a time and day the planner fits it in where it makes sense.")
        }
    }

    private func quickTime(_ title: String, hour: Int, minute: Int) -> some View {
        Button(title) {
            time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: time) ?? time
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var resultSections: some View {
        if isList {
            batchSections
        } else if query.count < 2 {
            if !popular.isEmpty {
                Section("Popular in \(destinationName.isEmpty ? "this area" : destinationName)") {
                    ForEach(popular, id: \.self) { item in row(item) }
                }
            }
        } else {
            Section {
                if searching && near.isEmpty && far.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                ForEach(near, id: \.self) { item in row(item) }
                if searched && !searching && near.isEmpty && far.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing found", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try the full name, or add the city, for example \"\(query), \(destinationName.isEmpty ? "Lisbon" : destinationName)\".")
                    }
                }
            } header: {
                Text("Places")
            }

            if !far.isEmpty {
                Section {
                    ForEach(far.prefix(4), id: \.self) { item in row(item) }
                } header: {
                    Text("Far from \(destinationName.isEmpty ? "your destination" : destinationName)")
                } footer: {
                    Text("These are in another area and probably not what you mean.")
                }
            }
        }
    }

    // MARK: Several places

    @ViewBuilder
    private var batchSections: some View {
        Section {
            Button {
                Task { await findBatch() }
            } label: {
                HStack {
                    Label("Find the places in this text", systemImage: "text.magnifyingglass")
                    Spacer()
                    if batchBusy { ProgressView() }
                }
            }
            .disabled(batchBusy)
            if let batchMessage {
                Text(batchMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(AIRouter.current(geminiKey: secrets.keys.gemini) == nil
                 ? "Looks like several places. They are split at numbers, lines and \"or\". Turn on an AI engine in Settings for better results with long text."
                 : "Looks like several places. The AI picks out the names, then each one is searched on the map.")
        }

        if !batch.isEmpty {
            Section("Found") {
                ForEach($batch) { $entry in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Include", isOn: $entry.include)
                            .labelsHidden()
                            .disabled(entry.item == nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item?.name ?? entry.title)
                                .font(.subheadline.weight(.medium))
                            if let item = entry.item {
                                Text(subtitle(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                Label("No match for \"\(entry.title)\"", systemImage: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let when = whenText(entry) {
                                Label(when, systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            Section {
                let count = batch.filter { $0.include && $0.item != nil }.count
                Button {
                    addBatch()
                } label: {
                    Text("Add \(count) \(count == 1 ? "place" : "places")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
                .listRowBackground(Color.clear)
            }
        }
    }

    private func whenText(_ entry: BatchEntry) -> String? {
        let time = entry.minute ?? (useTime ? minute : nil)
        let number = entry.day ?? (day > 0 ? day : nil)
        return MustSee.whenText(minute: time, day: number)
    }

    private func addBatch() {
        for entry in batch where entry.include {
            guard let item = entry.item else { continue }
            onAdd(MustSee(item: item,
                          preferredMinute: entry.minute ?? (useTime ? minute : nil),
                          preferredDay: entry.day ?? (day > 0 ? day : nil)))
        }
        dismiss()
    }

    /// Picks the places out of the text (AI when available, else by splitting) and searches each on the map.
    private func findBatch() async {
        batchBusy = true
        batchMessage = nil
        defer { batchBusy = false }

        var wanted: [(title: String, minute: Int?, day: Int?)] = []
        if let engine = AIRouter.current(geminiKey: secrets.keys.gemini),
           let result = try? await engine.extractItinerary(text: text, context: AIContext(destination: destinationName)) {
            for stop in result.days.flatMap(\.stops) {
                let hint = MustSeeParser.parse(stop.title + " " + stop.notes)
                let minute = stop.hour.map { $0 * 60 + (stop.minute ?? 0) } ?? hint.minute
                wanted.append((stop.title, minute, hint.day))
            }
        }
        if wanted.isEmpty {
            wanted = MustSeeParser.split(text).map { ($0.query, $0.minute, $0.day) }
        }
        guard !wanted.isEmpty else {
            batch = []
            batchMessage = "I couldn't find any place names in that text."
            return
        }

        var entries: [BatchEntry] = []
        for place in wanted.prefix(15) {
            var entry = BatchEntry(title: place.title, minute: place.minute, day: place.day)
            entry.item = await lookUp(place.title)
            entry.include = entry.item != nil
            entries.append(entry)
            batch = entries
            // MapKit limits how fast searches can follow each other.
            try? await Task.sleep(for: .milliseconds(150))
        }
        let missing = entries.filter { $0.item == nil }.count
        batchMessage = missing == 0 ? nil : "\(missing) not found on the map. Search them one by one, or add the city to the name."
    }

    /// The best match close to the destination; tries again with the destination's name added.
    private func lookUp(_ name: String) async -> MKMapItem? {
        var queries = [name]
        if !destinationName.isEmpty { queries.append("\(name), \(destinationName)") }
        for query in queries {
            let items = (try? await PlaceSearchService.search(query: query, region: region)) ?? []
            if let match = PlaceSearchService.partition(items, around: center, within: 150_000).near.first {
                return match
            }
        }
        return nil
    }

    private func row(_ item: MKMapItem) -> some View {
        Button {
            add(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: StopCategory(poi: item.pointOfInterestCategory).symbol)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Place")
                        .foregroundStyle(.primary)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityLabel("Add \(item.name ?? "place")")
    }

    private func subtitle(_ item: MKMapItem) -> String {
        var parts: [String] = []
        if let center {
            parts.append("\(Format.distance(RoutingService.straightLine(from: center, to: item.placemark.coordinate))) from the centre")
        }
        if let address = item.placemark.title, !address.isEmpty {
            parts.append(address)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func add(_ item: MKMapItem) {
        onAdd(MustSee(item: item, preferredMinute: minute, preferredDay: dayNumber))
        dismiss()
    }

    /// Searches while typing, after a short pause.
    private func search() async {
        let wanted = query
        guard wanted.count >= 2, !isList else {
            near = []
            far = []
            searching = false
            searched = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        searching = true
        let items = (try? await PlaceSearchService.search(query: wanted, region: region)) ?? []
        guard !Task.isCancelled else { return }
        let split = PlaceSearchService.partition(items, around: center, within: 150_000)
        near = split.near
        far = split.far
        searching = false
        searched = true
    }
}
