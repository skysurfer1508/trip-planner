import Foundation
import CoreLocation

/// Is a place visited outside, inside, or both? Used to move a rainy day indoors.
enum PlaceSetting {
    case indoor, outdoor, mixed

    private static let indoorWords = [
        "museum", "museu", "museo", "musée", "musee", "gallery", "galerie", "galeria", "galleria", "exhibit",
        "aquarium", "oceanário", "oceanario", "cathedral", "catedral", "church", "igreja", "iglesia", "église",
        "eglise", "kirche", "chiesa", "basilica", "chapel", "mosque", "moschee", "synagogue", "theater", "theatre",
        "teatro", "opera", "cinema", "library", "biblioteca", "bibliothek", "mall", "shopping", "centro comercial",
        "indoor", "spa", "thermal", "planetarium", "science", "casino", "bowling", "escape room", "arcade",
    ]

    private static let outdoorWords = [
        "park", "parque", "garden", "gardens", "garten", "jardim", "jardín", "jardin", "giardino", "beach",
        "praia", "playa", "plage", "strand", "spiaggia", "viewpoint", "lookout", "miradouro", "mirador",
        "aussichts", "belvedere", "trail", "hike", "wanderweg", "square", "plaza", "praça", "praca", "platz",
        "piazza", "bridge", "brücke", "ponte", "puente", "fountain", "brunnen", "zoo", "cemetery", "friedhof",
        "cemitério", "promenade", "waterfront", "lake", "river", "ruins", "walking tour", "waterfall", "canyon",
    ]

    /// Short keywords ("spa", "mall", "park") must be whole words so "Spanish Steps" isn't a spa;
    /// longer ones match the start of a word ("museum" in "museums").
    static func matches(_ text: String, _ keyword: String) -> Bool {
        let pattern = keyword.count <= 4 ? "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                                         : "\\b\(NSRegularExpression.escapedPattern(for: keyword))"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func classify(name: String, kind: DiscoverKind?, category: StopCategory?) -> PlaceSetting {
        if let kind {
            switch kind {
            case .food, .cafe, .nightlife: return .indoor
            default: break
            }
        }
        if let category {
            switch category {
            case .food, .cafe, .nightlife, .hotel: return .indoor
            case .transport: return .mixed
            default: break
            }
        }

        let lower = name.lowercased()
        let inside = indoorWords.contains { matches(lower, $0) }
        let outside = outdoorWords.contains { matches(lower, $0) }
        if inside && outside { return .mixed }
        if inside { return .indoor }
        if outside { return .outdoor }

        switch kind {
        case .culture: return .indoor
        case .nature: return .outdoor
        default: return .mixed
        }
    }
}

extension Stop {
    var setting: PlaceSetting {
        PlaceSetting.classify(name: name, kind: nil, category: category)
    }
}

/// Picks indoor replacements for the outdoor stops of a rainy day.
enum RainPlanner {
    struct OutdoorStop {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    struct Proposal {
        let outdoorID: String
        let place: SuggestedPlace
    }

    /// Indoor places that aren't already in the trip.
    static func indoorCandidates(_ places: [SuggestedPlace], excludingNames: Set<String>) -> [SuggestedPlace] {
        let known = Set(excludingNames.map { NameMatch.normalized($0) })
        var seen = Set<String>()
        return places.filter { place in
            guard PlaceSetting.classify(name: place.name, kind: place.kind, category: nil) == .indoor else { return false }
            let key = NameMatch.normalized(place.name)
            guard !known.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
    }

    /// One replacement per outdoor stop, the best-rated one close to it; nothing is used twice.
    static func proposals(for outdoor: [OutdoorStop],
                          candidates: [SuggestedPlace],
                          maxDistance: Double = 4_000) -> [Proposal] {
        var used = Set<String>()
        var result: [Proposal] = []
        for stop in outdoor {
            let ranked = candidates
                .filter { !used.contains($0.id) }
                .compactMap { place -> (SuggestedPlace, Double)? in
                    let distance = RoutingService.straightLine(from: stop.coordinate, to: place.coordinate)
                    guard distance <= maxDistance else { return nil }
                    return (place, max(place.score, 0.05) / (1 + distance / 1_500))
                }
                .sorted { $0.1 > $1.1 }
            if let best = ranked.first {
                used.insert(best.0.id)
                result.append(Proposal(outdoorID: stop.id, place: best.0))
            }
        }
        return result
    }
}
