import Foundation
import MapKit

/// Collects real places around the destination (OpenTripMap, Tripadvisor, Apple Maps), then lets
/// `AutoPlanner` turn them into days.
enum AutoPlanService {
    struct Output {
        var days: [PlannedDay]
        var notices: [String]
        var candidateCount: Int
        /// Every place that was considered, so single days can be changed afterwards.
        var candidates: [PlanCandidate]
        /// The traveller's own places that did not fit on any day.
        var leftOut: [PlanCandidate] = []
    }

    static func build(prefs: TripPreferences,
                      center: CLLocationCoordinate2D,
                      mustSees: [MustSee],
                      fixed: [PlanCandidate] = [],
                      fillGaps: Bool = true,
                      keys: APIKeys,
                      windows: [DayWindow] = [],
                      variation: Double = 0.3) async -> Output {
        var candidates: [PlanCandidate] = []
        var notices: [String] = []
        let radius = prefs.transport.searchRadius
        let kinds = Array(Set(prefs.neededKinds))

        // 1. Popular places per kind. Tripadvisor is only used for sights and food to protect its
        //    free monthly allowance.
        await withTaskGroup(of: SuggestionResult.self) { group in
            for kind in kinds {
                let kindKeys = (kind == .sights || kind == .food)
                    ? keys
                    : APIKeys(openTripMap: keys.openTripMap, tripadvisor: "", gemini: "")
                group.addTask {
                    await SuggestionService.load(kind: kind, center: center, radiusMeters: radius, keys: kindKeys)
                }
            }
            for await result in group {
                notices.append(contentsOf: result.notices)
                candidates.append(contentsOf: result.places.map(candidate(from:)))
            }
        }

        // 2. Extra searches for the user's taste: cuisines, vegetarian, nightlife style.
        var searches: [(query: String, kind: DiscoverKind, tags: [String])] = []
        for name in prefs.cuisines.sorted().prefix(3) {
            if let cuisine = Cuisine(rawValue: name) {
                searches.append((cuisine.query, .food, [cuisine.rawValue]))
            }
        }
        if prefs.vegetarian {
            searches.append(("vegetarian restaurant", .food, ["vegetarian"]))
        }
        if prefs.wantsNightlife {
            searches.append((prefs.nightlifeStyle.searchQuery, .nightlife, []))
        }
        for search in searches {
            let categories = search.kind == .nightlife ? DiscoverKind.nightlife.appleCategories : DiscoverKind.food.appleCategories
            let items = (try? await PlaceSearchService.nearby(query: search.query,
                                                              categories: categories,
                                                              center: center,
                                                              radius: min(radius, 4_000))) ?? []
            for item in items.prefix(15) {
                let coordinate = item.placemark.coordinate
                candidates.append(PlanCandidate(id: "apple-\(search.query)-\(item.name ?? "")-\(coordinate.latitude)",
                                                name: item.name ?? "Place",
                                                coordinate: coordinate,
                                                kind: search.kind,
                                                score: 0.55,
                                                address: item.placemark.title ?? "",
                                                cuisines: search.tags))
            }
        }

        // 3. Places the user insists on.
        candidates.append(contentsOf: mustSees.map { entry in
            var candidate = entry.candidate()
            // A suggested time must leave room before the day ends (night views when there is no nightlife).
            if candidate.timeIsSuggested, let minute = candidate.preferredMinute {
                candidate.preferredMinute = min(minute, max(prefs.endLimitMinutes - 120, 9 * 60))
            }
            return candidate
        })

        if fillGaps && keys.openTripMap.isEmpty && keys.tripadvisor.isEmpty {
            notices.append("Only Apple Maps places were available, so there is no popularity ranking. Add a free OpenTripMap key in Settings for better picks.")
        }

        candidates.append(contentsOf: fixed)

        var days: [PlannedDay]
        if !fillGaps {
            // Only the traveller's own places: arrange them, don't add anything.
            let own = candidates.filter(\.isMustSee)
            days = AutoPlanner.arrange(places: own, prefs: prefs, center: center, windows: windows).days
        } else {
            var generator = SystemRandomNumberGenerator()
            days = AutoPlanner.generate(candidates: candidates,
                                        prefs: prefs,
                                        center: center,
                                        variation: variation,
                                        windows: windows,
                                        using: &generator)
        }

        // Every place of the traveller's own must be in the plan or be reported, never silently lost.
        let pool = AutoPlanner.dedupe(candidates)
        let own = pool.filter(\.isMustSee)
        let planned = Set(days.flatMap { $0.stops.map(\.candidate.id) })
        let missing = own.filter { !planned.contains($0.id) }
        var leftOut: [PlanCandidate] = []
        if !missing.isEmpty {
            let result = AutoPlanner.placeMissing(missing, into: days, prefs: prefs, windows: windows)
            days = result.days
            leftOut = result.leftOut
        }
        if !leftOut.isEmpty {
            let names = leftOut.map(\.name).joined(separator: ", ")
            notices.append("\(own.count - leftOut.count) of your \(own.count) places are in the plan. These didn't fit in the days available: \(names). You can add them in the walk-through, or add a day to the trip.")
        }
        return Output(days: days,
                      notices: Array(Set(notices)).sorted(),
                      candidateCount: candidates.count,
                      candidates: pool,
                      leftOut: leftOut)
    }

    static func candidate(from place: SuggestedPlace) -> PlanCandidate {
        PlanCandidate(id: place.id,
                      name: place.name,
                      coordinate: place.coordinate,
                      kind: place.kind,
                      score: place.score,
                      address: place.address ?? "",
                      priceLevel: place.priceLevel,
                      cuisines: place.cuisines)
    }
}
