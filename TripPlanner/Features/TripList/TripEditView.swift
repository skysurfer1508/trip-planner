import SwiftUI
import SwiftData
import MapKit

/// Edit an existing trip. New trips use `NewTripWizard`.
struct TripEditView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var destination = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    @State private var isSaving = false
    @State private var transport: TripPreferences.Transport = .walking

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    Group {
                        TextField("Name (e.g. Summer in Lisbon)", text: $name)
                    }
                    .listRowBackground(Theme.surface)
                }

                Section("Destination") {
                    Group {
                        DestinationPicker(destination: $destination, coordinate: $coordinate) { city in
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = "Trip to \(city)"
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }

                Section("Dates") {
                    Group {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    Group {
                        Picker("Getting around", selection: $transport) {
                            ForEach(TripPreferences.Transport.allCases) { option in
                                Label(option.title, systemImage: option.symbol).tag(option)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                } footer: {
                    Text(transport == .transit
                         ? "Between stops you'll see the best public transport route, with lines, stops and times."
                         : "With public transport selected, routes between stops show real lines and times.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit trip")
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
        name = trip.name
        destination = trip.destination
        coordinate = trip.destinationCoordinate
        startDate = trip.startDate
        endDate = trip.endDate
        transport = trip.transport
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

        trip.name = name.trimmingCharacters(in: .whitespaces)
        trip.startDate = start
        trip.endDate = end
        trip.transport = transport
        trip.setDestination(name: cleanDestination, coordinate: finalCoordinate)
        trip.syncDays()
        dismiss()
    }
}
