import SwiftUI
import SwiftData
import MapKit

/// Create a new trip (`trip == nil`) or edit an existing one.
struct TripEditView: View {
    let trip: Trip?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var destination = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    @State private var completer = DestinationCompleter()
    @State private var suppressSuggestions = false
    @State private var isSaving = false
    @FocusState private var destinationFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Name (e.g. Summer in Lisbon)", text: $name)
                }

                Section {
                    TextField("Where are you going?", text: $destination)
                        .focused($destinationFocused)
                        .textInputAutocapitalization(.words)
                        .onChange(of: destination) { _, newValue in
                            if suppressSuggestions {
                                suppressSuggestions = false
                                return
                            }
                            coordinate = nil
                            completer.update(newValue)
                        }

                    if destinationFocused {
                        ForEach(completer.suggestions, id: \.self) { suggestion in
                            Button {
                                pick(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if coordinate != nil {
                        Label("Location set. Search, weather and ideas will use it.", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    NavigationLink {
                        DestinationIdeasView { idea in
                            apply(name: idea.displayName, coordinate: idea.coordinate)
                        }
                    } label: {
                        Label("Not sure yet? Browse destination ideas", systemImage: "sparkles")
                    }
                } header: {
                    Text("Destination")
                }

                Section("Dates") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
            }
            .navigationTitle(trip == nil ? "New trip" : "Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue { endDate = newValue }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let trip else { return }
        name = trip.name
        suppressSuggestions = !trip.destination.isEmpty
        destination = trip.destination
        coordinate = trip.destinationCoordinate
        startDate = trip.startDate
        endDate = trip.endDate
    }

    private func pick(_ suggestion: MKLocalSearchCompletion) {
        let display = DestinationCompleter.displayName(suggestion)
        suppressSuggestions = true
        destination = display
        completer.clear()
        destinationFocused = false
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = "Trip to \(suggestion.title)"
        }
        Task {
            if let resolved = await DestinationCompleter.resolve(suggestion) {
                coordinate = resolved.coordinate
            }
        }
    }

    private func apply(name displayName: String, coordinate newCoordinate: CLLocationCoordinate2D) {
        suppressSuggestions = true
        destination = displayName
        coordinate = newCoordinate
        completer.clear()
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = "Trip to \(displayName.components(separatedBy: ",").first ?? displayName)"
        }
    }

    private func save() async {
        isSaving = true
        let cleanDestination = destination.trimmingCharacters(in: .whitespaces)

        // Typed without picking a suggestion: still find its coordinates.
        var finalCoordinate = coordinate
        if finalCoordinate == nil && !cleanDestination.isEmpty {
            finalCoordinate = await DestinationCompleter.resolve(text: cleanDestination)?.coordinate
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = max(calendar.startOfDay(for: endDate), start)
        let cleanName = name.trimmingCharacters(in: .whitespaces)

        if let trip {
            trip.name = cleanName
            trip.startDate = start
            trip.endDate = end
            trip.setDestination(name: cleanDestination, coordinate: finalCoordinate)
            trip.syncDays()
        } else {
            let newTrip = Trip(name: cleanName, destination: cleanDestination, startDate: start, endDate: end)
            context.insert(newTrip)
            newTrip.setDestination(name: cleanDestination, coordinate: finalCoordinate)
            newTrip.syncDays()
        }
        dismiss()
    }
}
