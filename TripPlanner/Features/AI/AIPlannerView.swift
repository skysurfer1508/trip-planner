import SwiftUI

/// Draft a day-by-day plan with AI. The result goes through the same review screen as an import,
/// and only places that were found on the map can be added.
struct AIPlannerView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    private enum Phase {
        case form
        case working(String)
        case review
        case failed(String)
    }

    private static let interestOptions = ["Food", "History", "Art", "Nature", "Architecture", "Nightlife",
                                          "Shopping", "Family", "Beaches", "Hidden gems"]

    @State private var phase: Phase = .form
    @State private var days = 3
    @State private var interests: Set<String> = []
    @State private var pace = "Balanced"
    @State private var budget = "Mid-range"
    @State private var draft = ImportDraft()
    @State private var notice: String?

    private var maxDays: Int { max(trip.days.count, 1) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form: formView
                case .working(let message): workingView(message)
                case .review:
                    ItineraryReviewView(trip: trip, draft: draft, notice: notice) {
                        dismiss()
                    }
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Plan with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { days = min(max(trip.days.count, 1), 14) }
        }
    }

    private var formView: some View {
        let engine = AIRouter.current(geminiKey: secrets.keys.gemini)

        return Form {
            Section {
                if trip.destination.isEmpty {
                    Label("Set a destination first (Overview → Get ready).", systemImage: "mappin.slash")
                        .foregroundStyle(.orange)
                } else {
                    Label(trip.destination, systemImage: "mappin.and.ellipse")
                }
                Stepper("Days: \(days)", value: $days, in: 1...min(maxDays, 14))
            } footer: {
                Text("Matches the \(maxDays) \(maxDays == 1 ? "day" : "days") of your trip. Change the trip dates to plan more.")
            }

            Section("Interests") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Self.interestOptions, id: \.self) { option in
                        FilterChip(title: option, isOn: interests.contains(option)) {
                            if interests.contains(option) {
                                interests.remove(option)
                            } else {
                                interests.insert(option)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Style") {
                Picker("Pace", selection: $pace) {
                    ForEach(["Relaxed", "Balanced", "Packed"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                Picker("Budget", selection: $budget) {
                    ForEach(["Budget", "Mid-range", "Luxury"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    Task { await generate() }
                } label: {
                    Label("Draft itinerary", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine == nil || trip.destination.isEmpty)
            } footer: {
                if let engine {
                    Text("Uses \(engine.label). \(engine.label == "Gemini" ? "Your destination and interests are sent to Google." : "Stays on your phone.")")
                } else {
                    Text(AIError.unavailable.localizedDescription)
                }
            }
        }
    }

    private func workingView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
            if draft.total > 0 {
                ProgressView(value: Double(draft.progress), total: Double(draft.total))
                    .padding(.horizontal, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't draft a plan", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back") { phase = .form }
                .buttonStyle(.borderedProminent)
        }
    }

    private func generate() async {
        guard let engine = AIRouter.current(geminiKey: secrets.keys.gemini) else {
            phase = .failed(AIError.unavailable.localizedDescription)
            return
        }
        phase = .working("Drafting with \(engine.label)…")
        do {
            let request = DraftRequest(destination: trip.destination,
                                       days: days,
                                       interests: interests.sorted(),
                                       pace: pace,
                                       budget: budget)
            let itinerary = try await engine.draftItinerary(request)
            guard itinerary.stopCount > 0 else { throw AIError.badOutput }

            draft = ImportDraft()
            draft.load(itinerary, tripDays: trip.sortedDays)
            phase = .working("Finding the places on the map…")
            await draft.resolveAll(center: trip.destinationCoordinate, region: trip.searchRegion)
            notice = "Drafted by \(engine.label). Only places found on the map can be added."
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
