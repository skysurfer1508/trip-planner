import SwiftUI
import SwiftData

struct ChecklistView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @State private var showGenerator = false
    @State private var newTitle = ""
    @State private var newSection = "Other"

    private var items: [ChecklistItem] {
        trip.checklist.sorted { $0.order < $1.order }
    }

    /// Sections in the order they first appear.
    private var sections: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.section) {
            seen.append(item.section)
        }
        return seen
    }

    private var doneCount: Int { items.filter(\.isDone).count }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing on the list", systemImage: "checklist")
                } description: {
                    Text("Start from a suggested packing list based on weather and activities, or add your own items.")
                } actions: {
                    Button("Suggest a list") { showGenerator = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(doneCount) of \(items.count) done")
                            .font(.subheadline.bold())
                        ProgressView(value: Double(doneCount), total: Double(max(items.count, 1)))
                    }
                }
            }

            ForEach(sections, id: \.self) { section in
                Section(section) {
                    let rows = items.filter { $0.section == section }
                    ForEach(rows) { item in
                        Button {
                            item.isDone.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                                    .font(.title3)
                                Text(item.title)
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? .secondary : .primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            context.delete(rows[index])
                        }
                    }
                }
            }

            Section("Add item") {
                HStack {
                    TextField("e.g. Sunscreen", text: $newTitle)
                        .submitLabel(.done)
                        .onSubmit(addItem)
                    Menu {
                        Picker("Section", selection: $newSection) {
                            ForEach(availableSections, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Text(newSection)
                            .font(.footnote)
                    }
                    Button("Add", action: addItem)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Packing & to-do")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Suggest items…", systemImage: "wand.and.stars") { showGenerator = true }
                    Button("Uncheck all", systemImage: "arrow.counterclockwise") {
                        items.forEach { $0.isDone = false }
                    }
                    .disabled(doneCount == 0)
                    Button("Clear list", systemImage: "trash", role: .destructive) {
                        items.forEach { context.delete($0) }
                    }
                    .disabled(items.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showGenerator) {
            PackingGeneratorView(trip: trip)
        }
    }

    private var availableSections: [String] {
        let defaults = ["Documents & money", "Clothes", "Toiletries & health", "Electronics",
                        "Activities", PackingTemplates.beforeYouGo, "Other"]
        return defaults + sections.filter { !defaults.contains($0) }
    }

    private func addItem() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let item = ChecklistItem(title: title, section: newSection, order: (trip.checklist.map(\.order).max() ?? -1) + 1)
        context.insert(item)
        item.trip = trip
        newTitle = ""
    }
}

struct PackingGeneratorView: View {
    let trip: Trip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var options = PackingOptions()
    @State private var forecastNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Climate", selection: $options.climate) {
                        ForEach(PackingOptions.Climate.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let forecastNote {
                        Label(forecastNote, systemImage: "cloud.sun")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Stepper("Nights: \(options.nights)", value: $options.nights, in: 1...60)
                    Toggle("Expect rain", isOn: $options.rain)
                }
                Section("Activities") {
                    Toggle("Beach", isOn: $options.beach)
                    Toggle("Hiking", isOn: $options.hiking)
                    Toggle("Business", isOn: $options.business)
                    Toggle("Nightlife", isOn: $options.nightlife)
                    Toggle("Travelling with kids", isOn: $options.kids)
                }
            }
            .navigationTitle("Suggest a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: generate)
                }
            }
            .task { await prefill() }
        }
        .presentationDetents([.large])
    }

    /// Nights from the trip dates; climate and rain from the forecast when it's close enough.
    private func prefill() async {
        let calendar = Calendar.current
        let nights = calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.startDate),
                                             to: calendar.startOfDay(for: trip.endDate)).day ?? 3
        options.nights = max(1, nights)

        guard let coordinate = trip.anyCoordinate,
              let weather = await WeatherService.forecast(for: trip.startDate, at: coordinate) else { return }
        if weather.high >= 25 {
            options.climate = .warm
        } else if weather.high <= 10 {
            options.climate = .cold
        } else {
            options.climate = .mild
        }
        options.rain = weather.isWet
        forecastNote = "Forecast for the first day: \(weather.summary), \(weather.rainChance)% rain."
    }

    private func generate() {
        let existing = Set(trip.checklist.map { $0.title.lowercased() })
        var order = (trip.checklist.map(\.order).max() ?? -1) + 1
        for entry in PackingTemplates.items(for: options) where !existing.contains(entry.title.lowercased()) {
            let item = ChecklistItem(title: entry.title, section: entry.section, order: order)
            context.insert(item)
            item.trip = trip
            order += 1
        }
        dismiss()
    }
}
