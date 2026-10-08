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
    /// Which way the last step change went, so the page slides in from the matching side.
    @State private var movingForward = true
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
                progressBar
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.s)

                ZStack {
                    switch step {
                    case 0: whereStep
                    case 1: whenStep
                    default: startStep
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
            }
            .motion(Motion.state, value: step)
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
                        Button("Back") { go(to: step - 1) }
                    }
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDate < newValue { endDate = newValue }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    /// A thin bar that fills as the steps go by (step 1 of 3 is a third full).
    private var progressBar: some View {
        Capsule()
            .fill(Theme.separator)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: proxy.size.width * CGFloat(step + 1) / 3)
                }
            }
            .motion(Motion.state, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of 3")
    }

    // MARK: Steps

    private var whereStep: some View {
        Form {
            Section {
                Group {
                    DestinationPicker(destination: $destination, coordinate: $coordinate) { city in
                        if !nameEdited { name = "Trip to \(city)" }
                    }
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("Pick a suggestion so the app knows where you're going. It then finds places, weather and ideas for you.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var whenStep: some View {
        Form {
            Section("Name") {
                Group {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, _ in nameEdited = true }
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
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.vertical, Spacing.xs)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Actions

    private func advance() {
        go(to: step + 1)
    }

    private func go(to target: Int) {
        movingForward = target > step
        Motion.perform { step = target }
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
