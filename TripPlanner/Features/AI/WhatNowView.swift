import SwiftUI
import CoreLocation

/// "What should I do now?": the AI ranks real nearby places and your remaining stops for the
/// current time and weather. It can only choose from the list it is given.
struct WhatNowView: View {
    let day: Day
    let origin: CLLocationCoordinate2D?
    let remaining: [Stop]

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    private struct Pick: Identifiable {
        let id: String
        let name: String
        let reason: String
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance
        let address: String
        let category: StopCategory
        let isPlanned: Bool
    }

    private enum Phase {
        case loading
        case result([Pick])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var addedIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Thinking about your day…")
                case .failed(let message):
                    ContentUnavailableView("Can't suggest right now", systemImage: "wand.and.stars",
                                           description: Text(message))
                case .result(let picks):
                    if picks.isEmpty {
                        ContentUnavailableView("No ideas found", systemImage: "binoculars",
                                               description: Text("Nothing suitable nearby right now."))
                    } else {
                        List(picks) { pick in
                            row(pick)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("What now?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ pick: Pick) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: pick.category.symbol)
                    .foregroundStyle(pick.category.color)
                Text(pick.name)
                    .font(.headline)
                Spacer()
                if pick.isPlanned {
                    Text("Planned")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            Text(pick.reason)
                .font(.subheadline)
            Label(Format.distance(pick.distance), systemImage: "figure.walk")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    RoutingService.openInMaps(name: pick.name, coordinate: pick.coordinate, mode: .walk)
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.bordered)

                if !pick.isPlanned {
                    Button {
                        let stop = Stop(name: pick.name,
                                        latitude: pick.coordinate.latitude,
                                        longitude: pick.coordinate.longitude,
                                        address: pick.address,
                                        category: pick.category)
                        day.append(stop)
                        addedIDs.insert(pick.id)
                    } label: {
                        Label(addedIDs.contains(pick.id) ? "Added" : "Add to today",
                              systemImage: addedIDs.contains(pick.id) ? "checkmark" : "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(addedIDs.contains(pick.id))
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let origin else {
            phase = .failed("Location isn't available yet. Allow location access in Settings.")
            return
        }
        guard let engine = AIRouter.current(geminiKey: secrets.keys.gemini) else {
            phase = .failed(AIError.unavailable.localizedDescription)
            return
        }

        // Candidates come from real data; the AI only ranks them. Tripadvisor is left out here
        // to save its monthly allowance.
        let keys = APIKeys(openTripMap: secrets.keys.openTripMap, tripadvisor: "", gemini: "")
        async let sights = SuggestionService.load(kind: .sights, center: origin, radiusMeters: 2500, keys: keys)
        async let food = SuggestionService.load(kind: .food, center: origin, radiusMeters: 1500, keys: keys)
        let (sightResult, foodResult) = await (sights, food)

        var picksByID: [String: Pick] = [:]
        var candidates: [PickCandidate] = []

        for (index, stop) in remaining.prefix(4).enumerated() {
            let id = "stop-\(index)"
            let distance = RoutingService.straightLine(from: origin, to: stop.coordinate)
            let when = stop.plannedTime.map { " planned at \(Format.time($0))" } ?? ""
            candidates.append(PickCandidate(id: id, name: stop.name, detail: "already on today's plan\(when), \(Format.distance(distance)) away"))
            picksByID[id] = Pick(id: id, name: stop.name, reason: "", coordinate: stop.coordinate,
                                 distance: distance, address: stop.address, category: stop.category, isPlanned: true)
        }
        let nearby = (sightResult.places.sorted { $0.score > $1.score }.prefix(6))
            + (foodResult.places.sorted { $0.score > $1.score }.prefix(6))
        for place in nearby {
            candidates.append(PickCandidate(id: place.id,
                                            name: place.name,
                                            detail: "\(place.kind.title), \(Format.distance(place.distance)) away"))
            picksByID[place.id] = Pick(id: place.id, name: place.name, reason: "", coordinate: place.coordinate,
                                       distance: place.distance, address: place.address ?? "",
                                       category: place.kind.stopCategory, isPlanned: false)
        }
        guard !candidates.isEmpty else {
            phase = .result([])
            return
        }

        let weather = await WeatherService.forecast(for: Date(), at: origin)
            .map { "\($0.summary), \($0.rainChance)% chance of rain" }
        let request = PicksRequest(now: Format.time(Date()),
                                   weather: weather,
                                   remaining: remaining.map(\.name),
                                   candidates: candidates)
        do {
            let ranked = try await engine.rankPicks(request)
            let picks: [Pick] = ranked.compactMap { item in
                guard let base = picksByID[item.id] else { return nil }
                return Pick(id: base.id, name: base.name, reason: item.reason, coordinate: base.coordinate,
                            distance: base.distance, address: base.address, category: base.category,
                            isPlanned: base.isPlanned)
            }
            phase = .result(Array(picks.prefix(3)))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
