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
    @State private var changingID: UUID?
    @FocusState private var focused: Bool

    /// One place found in a pasted list.
    private struct BatchEntry: Identifiable {
        let id = UUID()
        var title: String
        var minute: Int?
        /// The time was chosen for the place (best time to visit), not stated in the text.
        var suggested = false
        var day: Int?
        var kind: DiscoverKind?
        var item: MKMapItem?
        /// Other places the name could mean, best first.
        var options: [MKMapItem] = []
        /// The match is a sure one; otherwise the row asks the traveller to check it.
        var confident = true
        var include = true
    }

    /// What the text says, worked out once per keystroke (not once per use).
    @State private var parsed = MustSeeParser.parse("")
    /// Several places in one text: they are found together instead of searched as one name.
    @State private var isList = false
    private var query: String { parsed.query }

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
            .onChange(of: text) { _, newValue in
                parsed = MustSeeParser.parse(newValue)
                isList = MustSeeParser.looksLikeList(newValue)
            }
            .onAppear { focused = true }
            .sheet(isPresented: Binding(get: { changingID != nil }, set: { if !$0 { changingID = nil } })) {
                PlacePickerView(query: batch.first { $0.id == changingID }?.title ?? "", region: region) { item in
                    if let id = changingID {
                        update(id) { entry in
                            entry.item = item
                            entry.confident = true
                            entry.include = true
                        }
                    }
                }
            }
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
                    .foregroundStyle(Theme.inkSecondary)
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
                HStack(spacing: Spacing.s) {
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
                    HStack(spacing: Spacing.m) {
                        ProgressView()
                        Text("Searching…").foregroundStyle(Theme.inkSecondary)
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
                    .foregroundStyle(Theme.inkSecondary)
            }
        } footer: {
            Text(AIRouter.current(geminiKey: secrets.keys.gemini) == nil
                 ? "Looks like several places. They are split at numbers, lines and \"or\". Turn on an AI engine in Settings for better results with long text."
                 : "Looks like several places. The AI picks out the names, then each one is searched on the map.")
        }

        if !batch.isEmpty {
            Section("Found") {
                ForEach($batch) { $entry in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Toggle("Include", isOn: $entry.include)
                            .labelsHidden()
                            .disabled(entry.item == nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item?.name ?? entry.title)
                                .font(.subheadline.weight(.medium))
                            if let item = entry.item {
                                Text(subtitle(item))
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(2)
                            } else {
                                Label("No match for \"\(entry.title)\"", systemImage: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warning)
                            }
                            if entry.item != nil && !entry.confident {
                                Label("Check this match", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warning)
                            }
                            if let when = whenText(entry) {
                                Label(when, systemImage: entry.suggested && entry.minute != nil ? "sparkles" : "clock")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Spacer(minLength: 0)
                        entryMenu(entry.id)
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
        return MustSee.whenText(minute: time, day: number, suggested: entry.minute != nil && entry.suggested)
    }

    private struct TimeChoice: Identifiable {
        let title: String
        let minute: Int
        var id: String { title }
    }

    private static let timeChoices: [TimeChoice] = [
        TimeChoice(title: "Morning", minute: 570),
        TimeChoice(title: "Afternoon", minute: 870),
        TimeChoice(title: "Evening", minute: 1110),
        TimeChoice(title: "Night", minute: 1260),
    ]

    /// The time, day and place options of one found place.
    private func entryMenu(_ id: UUID) -> some View {
        Menu {
            timeMenuSection(id)
            dayMenuSection(id)
            otherMatchesSection(id)
            Section {
                Button("Search for another place…", systemImage: "magnifyingglass") { changingID = id }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Options")
    }

    private func timeMenuSection(_ id: UUID) -> some View {
        Section("Time") {
            Button("Let the plan decide", systemImage: "wand.and.stars") {
                update(id) { entry in
                    entry.minute = nil
                    entry.suggested = false
                }
            }
            ForEach(Self.timeChoices) { choice in
                Button(choice.title) {
                    update(id) { entry in
                        entry.minute = choice.minute
                        entry.suggested = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayMenuSection(_ id: UUID) -> some View {
        if dayCount > 1 {
            Section("Day") {
                Button("Any day") {
                    update(id) { entry in entry.day = nil }
                }
                ForEach(1...dayCount, id: \.self) { number in
                    Button("Day \(number)") {
                        update(id) { entry in entry.day = number }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func otherMatchesSection(_ id: UUID) -> some View {
        let options: [MKMapItem] = batch.first(where: { $0.id == id })?.options ?? []
        if options.count > 1 {
            Section("Other matches") {
                ForEach(Array(options.dropFirst().prefix(3)), id: \.self) { option in
                    Button(option.name ?? "Place") {
                        update(id) { entry in
                            entry.item = option
                            entry.confident = true
                        }
                    }
                }
            }
        }
    }

    private static func discoverKind(for name: String) -> DiscoverKind? {
        switch name {
        case "food": return .food
        case "cafe": return .cafe
        case "nightlife": return .nightlife
        default: return nil
        }
    }

    private func update(_ id: UUID, _ change: (inout BatchEntry) -> Void) {
        guard let index = batch.firstIndex(where: { $0.id == id }) else { return }
        change(&batch[index])
    }

    private func addBatch() {
        for entry in batch where entry.include {
            guard let item = entry.item else { continue }
            let time = entry.minute ?? (useTime ? minute : nil)
            var wish = MustSee(item: item,
                               preferredMinute: time,
                               preferredDay: entry.day ?? (day > 0 ? day : nil))
            wish.timeIsSuggested = entry.minute != nil && entry.suggested
            wish.kindHint = entry.kind
            onAdd(wish)
        }
        dismiss()
    }

    /// Picks the places out of the text (the AI when there is one, else by splitting it), keeps the
    /// times the text states, suggests a time for the rest, and finds each place on the map.
    private func findBatch() async {
        batchBusy = true
        batchMessage = nil
        defer { batchBusy = false }

        // What a plain reading of the text says: names, times, days.
        let plain = MustSeeParser.split(text)

        var wishes: [PlaceWish] = []
        var textOnly = Set<UUID>()
        if let engine = AIRouter.current(geminiKey: secrets.keys.gemini),
           let result = try? await engine.extractPlaces(text: text, destination: destinationName), !result.isEmpty {
            wishes = result
            // The AI can miss a time that is written plainly; the text reading catches it.
            for index in wishes.indices where wishes[index].statedMinute == nil || wishes[index].day == nil {
                guard let match = plain.first(where: { PlaceFinder.similarity($0.query, wishes[index].name) > 0.45 }) else { continue }
                if wishes[index].statedMinute == nil, let minute = match.minute {
                    wishes[index].statedMinute = minute
                    wishes[index].suggestedMinute = nil
                }
                if wishes[index].day == nil { wishes[index].day = match.day }
            }
            // The AI sometimes stops after a few places. Anything the plain reading found that the AI did
            // not mention is added, so a pasted list is never cut short.
            if plain.count >= 3 {
                for parsed in plain where !wishes.contains(where: { PlaceFinder.similarity(parsed.query, $0.name) > 0.45 }) {
                    var wish = PlaceWish(name: parsed.query)
                    wish.statedMinute = parsed.minute
                    wish.day = parsed.day
                    textOnly.insert(wish.id)
                    wishes.append(wish)
                }
            }
        } else {
            wishes = plain.map { parsed in
                var wish = PlaceWish(name: parsed.query)
                wish.statedMinute = parsed.minute
                wish.day = parsed.day
                return wish
            }
        }
        guard !wishes.isEmpty else {
            batch = []
            batchMessage = "I couldn't find any place names in that text."
            return
        }

        var entries: [BatchEntry] = []
        for wish in wishes.prefix(40) {
            var entry = BatchEntry(title: wish.name)
            entry.day = wish.day
            entry.kind = Self.discoverKind(for: wish.kind)
            if let stated = wish.statedMinute {
                entry.minute = stated
            } else if let suggestion = wish.suggestedMinute ?? MustSeeParser.suggestedMinute(forName: wish.name) {
                entry.minute = suggestion
                entry.suggested = true
            }
            let matches = await PlaceFinder.find(name: wish.name, alternatives: wish.alternativeNames,
                                                 center: center, region: region, city: destinationName)
            entry.options = matches.map(\.item)
            entry.item = matches.first?.item
            entry.confident = matches.first?.isConfident ?? false
            // Names only the plain reading found are ticked only when the match is certain.
            entry.include = entry.item != nil && (entry.confident || !textOnly.contains(wish.id))
            entries.append(entry)
            batch = entries
        }
        let missing = entries.filter { $0.item == nil }.count
        let unsure = entries.filter { $0.item != nil && !$0.confident }.count
        var notes: [String] = []
        if missing > 0 { notes.append("\(missing) not found on the map. Use ⋯ → Search for another place.") }
        if unsure > 0 { notes.append("\(unsure) \(unsure == 1 ? "match is" : "matches are") not certain: check the ones marked.") }
        batchMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func row(_ item: MKMapItem) -> some View {
        Button {
            add(item)
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: StopCategory(poi: item.pointOfInterestCategory).symbol)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Place")
                        .foregroundStyle(.primary)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
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
        if let address = item.readableAddress, !address.isEmpty {
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
        let matches = await PlaceFinder.search(query: wanted, center: center, region: region)
        guard !Task.isCancelled else { return }
        let split = PlaceSearchService.partition(matches.map(\.item), around: center, within: 150_000)
        near = split.near
        far = split.far
        searching = false
        searched = true
    }
}
