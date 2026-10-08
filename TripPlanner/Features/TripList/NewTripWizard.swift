import SwiftUI
import SwiftData
import MapKit

enum TripStartAction {
    case importProgram, autoPlan
}

/// Three short steps: where, when, how to start.
struct NewTripWizard: View {
    /// Called after the trip is created; `startAction` is what the user picked in the last step.
    var onCreated: (Trip, TripStartAction?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var destination = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var nameEdited = false
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State private var isCreating = false

    private var canContinue: Bool {
        switch step {
        case 0: !destination.trimmingCharacters(in: .whitespaces).isEmpty
        case 1: !name.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressDots
                    .padding(.top, Spacing.s)

                Group {
                    switch step {
                    case 0: whereStep
                    case 1: whenStep
                    default: startStep
                    }
                }
            }
            .navigationTitle(["Where to?", "When?", "How to start?"][min(step, 2)])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step == 0 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                if step < 2 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") { advance() }
                            .disabled(!canContinue)
                    }
                }
                if step > 0 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { step -= 1 }
                    }
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue { endDate = newValue }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private var progressDots: some View {
        HStack(spacing: Spacing.s) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.accent : Color(.tertiarySystemFill))
                    .frame(width: index == step ? 28 : 10, height: 6)
            }
        }
        .animation(.snappy, value: step)
    }

    // MARK: Steps

    private var whereStep: some View {
        Form {
            Section {
                DestinationPicker(destination: $destination, coordinate: $coordinate) { city in
                    if !nameEdited { name = "Trip to \(city)" }
                }
            } footer: {
                Text("Pick a suggestion so the app knows where you're going. It then finds places, weather and ideas for you.")
            }
        }
    }

    private var whenStep: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, _ in nameEdited = true }
            }
            Section("Dates") {
                DatePicker("Start", selection: $startDate, displayedComponents: .date)
                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
        }
    }

    private var startStep: some View {
        List {
            Section {
                startButton("Start with an empty plan",
                            detail: "Add places yourself, or browse Discover.",
                            symbol: "square.and.pencil",
                            action: nil)
                startButton("Import my program",
                            detail: "A PDF, Word file or photo you already have.",
                            symbol: "doc.viewfinder",
                            action: .importProgram)
                startButton("Auto plan my trip",
                            detail: "Answer a few questions and get a day-by-day plan.",
                            symbol: "wand.and.stars",
                            action: .autoPlan)
            } footer: {
                Text("You can do any of these later from the trip's Overview.")
            }
        }
        .disabled(isCreating)
        .overlay {
            if isCreating { ProgressView() }
        }
    }

    private func startButton(_ title: String, detail: String, symbol: String, action: TripStartAction?) -> some View {
        Button {
            Task { await create(startWith: action) }
        } label: {
            HStack(spacing: Spacing.l) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: Radius.shape(Radius.small))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    // MARK: Actions

    private func advance() {
        step += 1
    }

    private func create(startWith action: TripStartAction?) async {
        isCreating = true
        let cleanDestination = destination.trimmingCharacters(in: .whitespaces)
        var finalCoordinate = coordinate
        if finalCoordinate == nil && !cleanDestination.isEmpty {
            finalCoordinate = await DestinationCompleter.resolve(text: cleanDestination)?.coordinate
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = max(calendar.startOfDay(for: endDate), start)
        let trip = Trip(name: name.trimmingCharacters(in: .whitespaces),
                        destination: cleanDestination,
                        startDate: start,
                        endDate: end)
        context.insert(trip)
        trip.setDestination(name: cleanDestination, coordinate: finalCoordinate)
        trip.syncDays()

        dismiss()
        onCreated(trip, action)
    }
}
