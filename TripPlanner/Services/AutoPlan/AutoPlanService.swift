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
    }

    static func build(prefs: TripPreferences,
                      center: CLLocationCoordinate2D,
                      mustSees: [MKMapItem],
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
        for item in mustSees {
            let coordinate = item.placemark.coordinate
            candidates.append(PlanCandidate(id: "must-\(item.name ?? "")-\(coordinate.latitude)",
                                            name: item.name ?? "Must-see",
                                            coordinate: coordinate,
                                            kind: .sights,
                                            score: 1,
                                            address: item.placemark.title ?? "",
                                            isMustSee: true))
        }

        if keys.openTripMap.isEmpty && keys.tripadvisor.isEmpty {
            notices.append("Only Apple Maps places were available, so there is no popularity ranking. Add a free OpenTripMap key in Settings for better picks.")
        }

        var generator = SystemRandomNumberGenerator()
        let days = AutoPlanner.generate(candidates: candidates,
                                        prefs: prefs,
                                        center: center,
                                        variation: variation,
                                        windows: windows,
                                        using: &generator)
        return Output(days: days,
                      notices: Array(Set(notices)).sorted(),
                      candidateCount: candidates.count,
                      candidates: AutoPlanner.dedupe(candidates))
    }

    private static func candidate(from place: SuggestedPlace) -> PlanCandidate {
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
