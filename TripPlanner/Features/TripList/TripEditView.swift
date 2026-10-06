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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Name (e.g. Summer in Lisbon)", text: $name)
                }

                Section("Destination") {
                    DestinationPicker(destination: $destination, coordinate: $coordinate) { city in
                        if name.trimmingCharacters(in: .whitespaces).isEmpty {
                            name = "Trip to \(city)"
                        }
                    }
                }

                Section("Dates") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
            }
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
        trip.setDestination(name: cleanDestination, coordinate: finalCoordinate)
        trip.syncDays()
        dismiss()
    }
}
