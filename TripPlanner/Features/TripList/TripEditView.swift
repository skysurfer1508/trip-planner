import SwiftUI
import SwiftData

/// Create a new trip (`trip == nil`) or edit an existing one.
struct TripEditView: View {
    let trip: Trip?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var destination = ""
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Name (e.g. Summer in Lisbon)", text: $name)
                    TextField("Destination (e.g. Lisbon)", text: $destination)
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
                    Button("Save", action: save)
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
        destination = trip.destination
        startDate = trip.startDate
        endDate = trip.endDate
    }

    private func save() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = max(calendar.startOfDay(for: endDate), start)
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanDestination = destination.trimmingCharacters(in: .whitespaces)

        if let trip {
            trip.name = cleanName
            trip.destination = cleanDestination
            trip.startDate = start
            trip.endDate = end
            trip.syncDays()
        } else {
            let newTrip = Trip(name: cleanName, destination: cleanDestination, startDate: start, endDate: end)
            context.insert(newTrip)
            newTrip.syncDays()
        }
        dismiss()
    }
}
