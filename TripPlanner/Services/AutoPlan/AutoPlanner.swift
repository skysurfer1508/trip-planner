import Foundation
import CoreLocation

// MARK: - Types

struct PlanCandidate: Identifiable {
    let id: String
    var name: String
    var coordinate: CLLocationCoordinate2D
    var kind: DiscoverKind
    /// Popularity 0...1.
    var score: Double
    var address = ""
    /// 1 ($) ... 4 ($$$$) when known.
    var priceLevel: Int?
    var cuisines: [String] = []
    var isMustSee = false
}

enum PlanSlot: String {
    case activity, lunch, cafe, dinner, nightlife
}

struct PlannedStop {
    let candidate: PlanCandidate
    let slot: PlanSlot
    /// Minutes after midnight.
    var startMinute: Int
    var durationMinutes: Int
}

struct PlannedDay {
    var stops: [PlannedStop]
    var theme: String
}

/// A small seedable generator so plans can be reproduced in tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Planner

/// Builds a day-by-day plan from a pool of real places and the user's answers. Pure logic with no
/// network or UI, so it is unit tested.
enum AutoPlanner {
    static func generate<G: RandomNumberGenerator>(candidates: [PlanCandidate],
                                                   prefs: TripPreferences,
                                                   center: CLLocationCoordinate2D,
                                                   variation: Double,
                                                   windows: [DayWindow] = [],
                                                   using rng: inout G) -> [PlannedDay] {
        let dayCount = max(prefs.days, 1)
        let pool = dedupe(candidates)
        let activityKinds = prefs.activityKinds
        let legScale = prefs.transport.legScale

        // Day centres: spread the best sightseeing candidates over `dayCount` compact areas.
        let activityPool = pool
            .filter { activityKinds.contains($0.kind) || $0.isMustSee }
            .sorted { adjusted($0, prefs) > adjusted($1, prefs) }
        let seeds = Array(activityPool.prefix(dayCount * 12))
        var centres = dayCentres(points: seeds.map(\.coordinate),
                                 weights: seeds.map { adjusted($0, prefs) },
                                 count: dayCount)
        while centres.count < dayCount { centres.append(center) }

        // Must-see places go to the day whose centre is closest.
        var reserved = Array(repeating: [PlanCandidate](), count: dayCount)
        var used = Set<String>()
        for place in pool where place.isMustSee {
            let index = centres.indices.min {
                RoutingService.straightLine(from: centres[$0], to: place.coordinate)
                    < RoutingService.straightLine(from: centres[$1], to: place.coordinate)
            } ?? 0
            reserved[index].append(place)
            used.insert(place.id)
        }

        func pick(kind: DiscoverKind, near: CLLocationCoordinate2D, rng: inout G) -> PlanCandidate? {
            var best: (place: PlanCandidate, value: Double)?
            var fallback: (place: PlanCandidate, distance: Double)?
            for place in pool where place.kind == kind && !used.contains(place.id) {
                let distance = RoutingService.straightLine(from: near, to: place.coordinate)
                if fallback == nil || distance < fallback!.distance {
                    fallback = (place, distance)
                }
                if distance > legScale * 5 { continue }
                let proximity = 1 / (1 + distance / legScale)
                let noise = 1 + variation * Double.random(in: -1...1, using: &rng)
                let value = adjusted(place, prefs) * proximity * noise
                if best == nil || value > best!.value {
                    best = (place, value)
                }
            }
            // Small pools: take the nearest unused place rather than leaving the slot empty.
            guard let chosen = best?.place ?? fallback?.place else { return nil }
            used.insert(chosen.id)
            return chosen
        }

        var days: [PlannedDay] = []
        for dayIndex in 0..<dayCount {
            let window = windows.indices.contains(dayIndex) ? windows[dayIndex] : DayWindow()
            // Start from the hotel when there is one; otherwise from the day's area.
            var current = window.anchor ?? centres[dayIndex]
            var slots: [(place: PlanCandidate, slot: PlanSlot)] = []
            var kindCursor = dayIndex

            func add(_ place: PlanCandidate?, _ slot: PlanSlot) {
                guard let place else { return }
                slots.append((place, slot))
                current = place.coordinate
            }
            func nextActivity(rng: inout G) -> PlanCandidate? {
                if !reserved[dayIndex].isEmpty {
                    return reserved[dayIndex].removeFirst()
                }
                for attempt in 0..<activityKinds.count {
                    let kind = activityKinds[(kindCursor + attempt) % activityKinds.count]
                    if let place = pick(kind: kind, near: current, rng: &rng) {
                        kindCursor += attempt + 1
                        return place
                    }
                }
                return nil
            }

            let activities = max(prefs.pace.activitiesPerDay, reserved[dayIndex].count)
            let before = (activities + 1) / 2
            for _ in 0..<before { add(nextActivity(rng: &rng), .activity) }
            if prefs.includeLunch { add(pick(kind: .food, near: current, rng: &rng), .lunch) }
            for _ in 0..<(activities - before) { add(nextActivity(rng: &rng), .activity) }
            if prefs.wantsCafes { add(pick(kind: .cafe, near: current, rng: &rng), .cafe) }
            if prefs.includeDinner { add(pick(kind: .food, near: current, rng: &rng), .dinner) }
            if prefs.wantsNightlife { add(pick(kind: .nightlife, near: current, rng: &rng), .nightlife) }

            let stops = schedule(slots,
                                 prefs: prefs,
                                 from: window.anchor,
                                 startMinute: max(prefs.dayStart.minutes, window.startMinute ?? 0),
                                 limit: min(prefs.endLimitMinutes, window.endMinute ?? Int.max))
            days.append(PlannedDay(stops: stops, theme: theme(for: stops)))
        }
        return days
    }

    // MARK: Scoring

    /// Popularity adjusted for the user's taste, budget and food preferences.
    static func adjusted(_ place: PlanCandidate, _ prefs: TripPreferences) -> Double {
        var value = place.score
        if prefs.interests.contains(.hiddenGems) && place.kind != .food {
            // Flatten the popularity curve so lesser-known places get a real chance.
            value = 0.35 + 0.3 * value
        }
        if place.kind == .food, let level = place.priceLevel {
            switch prefs.budget {
            case .budget: if level >= 3 { value *= 0.6 }
            case .midRange: if level >= 4 { value *= 0.7 }
            case .treat: if level >= 3 { value *= 1.15 }
            }
        }
        if place.kind == .food {
            let text = (place.cuisines + [place.name]).joined(separator: " ").lowercased()
            let wanted = prefs.cuisines.compactMap { Cuisine(rawValue: $0) }
            if wanted.contains(where: { cuisine in cuisine.keywords.contains { text.contains($0) } }) {
                value *= 1.3
            }
            if prefs.vegetarian && text.contains("vegetarian") {
                value *= 1.4
            }
        }
        if place.isMustSee { value = 10 }
        return value
    }

    // MARK: Day centres

    /// Weighted k-means over coordinates, returning centres ordered by how much popularity each
    /// area holds (day 1 gets the best area).
    static func dayCentres(points: [CLLocationCoordinate2D], weights: [Double], count: Int) -> [CLLocationCoordinate2D] {
        guard !points.isEmpty else { return [] }
        let k = min(count, points.count)
        if k <= 1 {
            return [mean(of: points, weights: weights)]
        }

        // Farthest-point start, beginning with the most popular point.
        var centres = [points[0]]
        while centres.count < k {
            let next = points.max { a, b in
                nearest(a, in: centres) < nearest(b, in: centres)
            }!
            centres.append(next)
        }

        var assignment = Array(repeating: 0, count: points.count)
        for _ in 0..<12 {
            for (index, point) in points.enumerated() {
                assignment[index] = centres.indices.min {
                    RoutingService.straightLine(from: point, to: centres[$0])
                        < RoutingService.straightLine(from: point, to: centres[$1])
                }!
            }
            for cluster in centres.indices {
                let members = points.indices.filter { assignment[$0] == cluster }
                guard !members.isEmpty else { continue }
                centres[cluster] = mean(of: members.map { points[$0] }, weights: members.map { weights[$0] })
            }
        }

        let totals = centres.indices.map { cluster in
            points.indices.filter { assignment[$0] == cluster }.reduce(0) { $0 + weights[$1] }
        }
        return centres.indices.sorted { totals[$0] > totals[$1] }.map { centres[$0] }
    }

    private static func nearest(_ point: CLLocationCoordinate2D, in centres: [CLLocationCoordinate2D]) -> Double {
        centres.map { RoutingService.straightLine(from: point, to: $0) }.min() ?? 0
    }

    private static func mean(of points: [CLLocationCoordinate2D], weights: [Double]) -> CLLocationCoordinate2D {
        let total = weights.reduce(0, +)
        guard total > 0 else {
            let n = Double(points.count)
            return CLLocationCoordinate2D(latitude: points.reduce(0) { $0 + $1.latitude } / n,
                                          longitude: points.reduce(0) { $0 + $1.longitude } / n)
        }
        var lat = 0.0
        var lon = 0.0
        for (point, weight) in zip(points, weights) {
            lat += point.latitude * weight
            lon += point.longitude * weight
        }
        return CLLocationCoordinate2D(latitude: lat / total, longitude: lon / total)
    }

    // MARK: Scheduling

    static func duration(for slot: PlanSlot, kind: DiscoverKind) -> Int {
        switch slot {
        case .lunch: return 60
        case .dinner: return 90
        case .cafe: return 30
        case .nightlife: return 120
        case .activity:
            switch kind {
            case .culture: return 120
            case .fun: return 120
            case .shopping: return 60
            default: return 90
            }
        }
    }

    /// Times from the day start: stay, then travel plus slack. Meals wait for their usual hour;
    /// anything that no longer fits before the end of the day is dropped.
    static func schedule(_ slots: [(place: PlanCandidate, slot: PlanSlot)],
                         prefs: TripPreferences,
                         from anchor: CLLocationCoordinate2D? = nil,
                         startMinute: Int? = nil,
                         limit: Int? = nil) -> [PlannedStop] {
        var result: [PlannedStop] = []
        var cursor = startMinute ?? prefs.dayStart.minutes
        var previous: CLLocationCoordinate2D? = anchor
        let limit = limit ?? prefs.endLimitMinutes

        for entry in slots {
            var start = cursor
            if let previous {
                start += travelMinutes(from: previous, to: entry.place.coordinate, transport: prefs.transport) + 5
            }
            start = (start + 4) / 5 * 5
            // A late start (after a flight) leaves no room for a lunch at 5 pm.
            if entry.slot == .lunch && start > 15 * 60 { continue }
            switch entry.slot {
            case .lunch: start = max(start, 12 * 60 + 15)
            case .dinner: start = max(start, prefs.isFamily ? 18 * 60 : 18 * 60 + 45)
            case .nightlife: start = max(start, 20 * 60 + 30)
            default: break
            }
            if start >= limit { continue }

            let length = duration(for: entry.slot, kind: entry.place.kind)
            result.append(PlannedStop(candidate: entry.place, slot: entry.slot, startMinute: start, durationMinutes: length))
            cursor = start + length
            previous = entry.place.coordinate
        }
        return result
    }

    static func travelMinutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                              transport: TripPreferences.Transport) -> Int {
        let meters = RoutingService.straightLine(from: from, to: to)
        let mode: TravelMode
        switch transport {
        case .walking: mode = meters > 2_500 ? .transit : .walk
        case .transit: mode = meters > 1_200 ? .transit : .walk
        case .car: mode = .drive
        }
        return Int((RoutingService.estimate(from: from, to: to, mode: mode) / 60).rounded(.up))
    }

    // MARK: Helpers

    static func dedupe(_ candidates: [PlanCandidate]) -> [PlanCandidate] {
        func key(_ name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        var result: [PlanCandidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let name = key(candidate.name)
            let duplicate = result.contains { existing in
                existing.kind == candidate.kind
                    && RoutingService.straightLine(from: existing.coordinate, to: candidate.coordinate) < 150
                    && (key(existing.name) == name || key(existing.name).contains(name) || name.contains(key(existing.name)))
            }
            if !duplicate { result.append(candidate) }
        }
        return result
    }

    static func theme(for stops: [PlannedStop]) -> String {
        var names: [String] = []
        for stop in stops where stop.slot == .activity {
            let name: String
            switch stop.candidate.kind {
            case .sights: name = "Sights"
            case .culture: name = "Museums & art"
            case .nature: name = "Nature"
            case .fun: name = "Fun"
            case .shopping: name = "Shopping"
            default: name = "Highlights"
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "Food & drink" : names.prefix(2).joined(separator: " & ")
    }
}
