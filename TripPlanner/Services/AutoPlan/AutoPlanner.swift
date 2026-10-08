import Foundation
import CoreLocation

// MARK: - Types

/// Real travel minutes between two places, when known (e.g. from a public transport lookup).
typealias TravelOverride = (CLLocationCoordinate2D, CLLocationCoordinate2D) -> Int?

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
    /// When the traveller wants to be there (minutes after midnight) and on which day (1 = first).
    var preferredMinute: Int?
    var preferredDay: Int?
    /// How long to stay, for a stop that is already in the trip (else a typical length is used).
    var fixedDuration: Int?
    /// The wanted time was chosen as the best time for this place, not asked for.
    var timeIsSuggested = false
    /// Set for a stop that is already in the trip; its details are kept when the plan is added.
    var existingKey: String?
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
    /// A start time the traveller asked for (minutes after midnight).
    var startOverride: Int?
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

        // The traveller's own places are spread over the days by area, but never onto a day with no
        // time left (the evening of arrival). Those with a wanted time are slotted in afterwards.
        var reserved = Array(repeating: [PlanCandidate](), count: dayCount)
        var timed = Array(repeating: [PlanCandidate](), count: dayCount)
        var used = Set<String>()
        let capacities = (0..<dayCount).map { index in
            capacity(prefs: prefs, window: windows.indices.contains(index) ? windows[index] : DayWindow())
        }
        for (index, group) in distribute(pool.filter(\.isMustSee), dayCount: dayCount, capacities: capacities).enumerated() {
            for place in group {
                if place.preferredMinute != nil {
                    timed[index].append(place)
                } else {
                    reserved[index].append(place)
                }
                used.insert(place.id)
            }
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
            reserved[dayIndex] = walkingOrder(reserved[dayIndex], from: current)
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

            // A restaurant the traveller already chose is that day's lunch or dinner.
            var untimedFood = reserved[dayIndex].filter { $0.kind == .food }
            reserved[dayIndex].removeAll { $0.kind == .food }
            let timedFood = timed[dayIndex].filter { $0.kind == .food }
            let lunchCovered = timedFood.contains { ($0.preferredMinute ?? 0) < 16 * 60 }
            let dinnerCovered = timedFood.contains { ($0.preferredMinute ?? 0) >= 16 * 60 }
            var lunchFixed: PlanCandidate?
            var dinnerFixed: PlanCandidate?
            if prefs.includeLunch && !lunchCovered && !untimedFood.isEmpty { lunchFixed = untimedFood.removeFirst() }
            if prefs.includeDinner && !dinnerCovered && !untimedFood.isEmpty { dinnerFixed = untimedFood.removeFirst() }
            reserved[dayIndex].append(contentsOf: untimedFood)

            let startMinute = max(prefs.dayStart.minutes, window.startMinute ?? 0)
            let limit = min(prefs.endLimitMinutes, window.endMinute ?? Int.max)
            // A short day (the evening of arrival) takes fewer activities, so dinner still fits.
            let budget = activityBudget(prefs: prefs, startMinute: startMinute, limit: limit,
                                        lunch: prefs.includeLunch && !lunchCovered,
                                        dinner: prefs.includeDinner && !dinnerCovered)
            let wanted = min(max(prefs.pace.activitiesPerDay - timed[dayIndex].count, 0), budget)
            let activities = max(wanted, reserved[dayIndex].count)
            let before = (activities + 1) / 2
            for _ in 0..<before { add(nextActivity(rng: &rng), .activity) }
            if prefs.includeLunch && !lunchCovered {
                add(lunchFixed ?? pick(kind: .food, near: current, rng: &rng), .lunch)
            }
            for _ in 0..<(activities - before) { add(nextActivity(rng: &rng), .activity) }
            if prefs.wantsCafes { add(pick(kind: .cafe, near: current, rng: &rng), .cafe) }
            if prefs.includeDinner && !dinnerCovered {
                add(dinnerFixed ?? pick(kind: .food, near: current, rng: &rng), .dinner)
            }
            if prefs.wantsNightlife { add(pick(kind: .nightlife, near: current, rng: &rng), .nightlife) }

            var stops = schedule(slots, prefs: prefs, from: window.anchor, startMinute: startMinute, limit: limit)
            if !timed[dayIndex].isEmpty {
                stops = insertTimed(timed[dayIndex], into: stops, prefs: prefs, anchor: window.anchor,
                                    startMinute: startMinute, limit: limit)
            }
            days.append(PlannedDay(stops: stops, theme: theme(for: stops)))
        }
        return days
    }

    // MARK: Spreading places over days

    /// How many sightseeing stops fit between the start and the end of a day once its meals are taken out,
    /// at about 100 minutes each with the way between them. A normal day is unchanged (a packed pace still
    /// gets five); an arrival evening gets one or two.
    static func activityBudget(prefs: TripPreferences, startMinute: Int, limit: Int, lunch: Bool, dinner: Bool) -> Int {
        var meals = 0
        if lunch && startMinute <= 15 * 60 { meals += 70 }          // later than that the lunch is skipped
        if dinner { meals += 100 }
        if prefs.wantsCafes { meals += 40 }
        if prefs.wantsNightlife { meals += 130 }
        let free = max(0, min(limit, 24 * 60) - startMinute - meals)
        return free / 100
    }

    /// Minutes of a day that can be used: from its start (after landing, or the usual start) to its end.
    static func availableMinutes(prefs: TripPreferences, window: DayWindow) -> Int {
        let start = max(prefs.dayStart.minutes, window.startMinute ?? 0)
        let end = min(prefs.endLimitMinutes, window.endMinute ?? Int.max)
        return max(0, end - start)
    }

    /// How many stops a day takes: about two hours each with the way between them. A day with
    /// under an hour left (the evening of arrival) takes none.
    static func capacity(prefs: TripPreferences, window: DayWindow) -> Int {
        let minutes = availableMinutes(prefs: prefs, window: window)
        return minutes < 60 ? 0 : max(1, minutes / 110)
    }

    /// Spreads places over the days: first the ones asked for on a day, then the rest by area, a compact
    /// area per day, the biggest areas on the days with the most time. A day never gets more than its
    /// capacity until every day is full.
    static func distribute(_ places: [PlanCandidate], dayCount: Int, capacities: [Int]) -> [[PlanCandidate]] {
        var buckets = Array(repeating: [PlanCandidate](), count: dayCount)
        var free = (0..<dayCount).map { capacities.indices.contains($0) ? capacities[$0] : 6 }
        var rest: [PlanCandidate] = []
        for place in places {
            if let day = place.preferredDay, (1...dayCount).contains(day) {
                buckets[day - 1].append(place)
                free[day - 1] -= 1
            } else {
                rest.append(place)
            }
        }
        guard !rest.isEmpty else { return buckets }

        let centres = dayCentres(points: rest.map(\.coordinate), weights: rest.map { _ in 1.0 }, count: dayCount)
        guard !centres.isEmpty else { return buckets }

        func nearestCentre(_ place: PlanCandidate) -> Int {
            centres.indices.min {
                RoutingService.straightLine(from: place.coordinate, to: centres[$0])
                    < RoutingService.straightLine(from: place.coordinate, to: centres[$1])
            } ?? 0
        }

        // Pair areas with days: the area with the most places goes to the day with the most room.
        var sizes = Array(repeating: 0, count: centres.count)
        for place in rest { sizes[nearestCentre(place)] += 1 }
        let areaOrder = centres.indices.sorted { sizes[$0] > sizes[$1] }
        let dayOrder = (0..<dayCount).sorted { free[$0] > free[$1] }
        var dayCentre = Array(repeating: centres[0], count: dayCount)
        for (rank, area) in areaOrder.enumerated() where rank < dayOrder.count {
            dayCentre[dayOrder[rank]] = centres[area]
        }

        func distance(_ place: PlanCandidate, day: Int) -> Double {
            RoutingService.straightLine(from: place.coordinate, to: dayCentre[day])
        }

        // Places close to an area centre first, so the clear cases settle before the borderline ones.
        let ordered = rest.sorted { a, b in
            RoutingService.straightLine(from: a.coordinate, to: centres[nearestCentre(a)])
                < RoutingService.straightLine(from: b.coordinate, to: centres[nearestCentre(b)])
        }
        for place in ordered {
            let byDistance = (0..<dayCount).sorted { distance(place, day: $0) < distance(place, day: $1) }
            // When every day is full, the extra place goes to the day with the most time, not to a short one.
            let day = byDistance.first { free[$0] > 0 }
                ?? (0..<dayCount).max { a, b in
                    let roomA = capacities.indices.contains(a) ? capacities[a] : 6
                    let roomB = capacities.indices.contains(b) ? capacities[b] : 6
                    return roomA != roomB ? roomA < roomB : buckets[a].count > buckets[b].count
                }
                ?? 0
            buckets[day].append(place)
            free[day] -= 1
        }
        return buckets
    }

    /// Short walking order starting near `start`, so the first place on a list is not simply the first stop.
    static func walkingOrder(_ places: [PlanCandidate], from start: CLLocationCoordinate2D?) -> [PlanCandidate] {
        guard places.count > 1 else { return places }
        if let start {
            let order = RouteOptimizer.order([start] + places.map(\.coordinate)).dropFirst().map { $0 - 1 }
            return order.map { places[$0] }
        }
        return RouteOptimizer.order(places.map(\.coordinate)).map { places[$0] }
    }

    /// Finds room for places that did not make it into a day: on the day they were asked for, else
    /// the day with the most room, as long as nothing else has to be dropped for it.
    static func placeMissing(_ missing: [PlanCandidate],
                             into days: [PlannedDay],
                             prefs: TripPreferences,
                             windows: [DayWindow]) -> (days: [PlannedDay], leftOut: [PlanCandidate]) {
        var days = days
        var leftOut: [PlanCandidate] = []
        for place in missing {
            var order = days.indices.sorted { days[$0].stops.count < days[$1].stops.count }
            if let wanted = place.preferredDay, days.indices.contains(wanted - 1) {
                order.removeAll { $0 == wanted - 1 }
                order.insert(wanted - 1, at: 0)
            }
            var placed = false
            for index in order {
                let window = windows.indices.contains(index) ? windows[index] : DayWindow()
                let before = days[index].stops.count
                let outcome = PlanEditor.apply([.add(place.id, after: nil)], to: days[index], pool: [place],
                                               usedElsewhere: [], prefs: prefs, window: window)
                if outcome.day.stops.count == before + 1,
                   outcome.day.stops.contains(where: { $0.candidate.id == place.id }) {
                    days[index] = outcome.day
                    placed = true
                    break
                }
            }
            if !placed { leftOut.append(place) }
        }
        return (days, leftOut)
    }

    struct Arrangement {
        var days: [PlannedDay]
        /// Places that did not fit on any day.
        var leftOut: [PlanCandidate]
    }

    /// Plans a trip with exactly the given places and nothing else: they are spread over the days by
    /// location, put in a short walking order and timed. Places with a wanted day or time keep it.
    static func arrange(places given: [PlanCandidate],
                        prefs: TripPreferences,
                        center: CLLocationCoordinate2D,
                        windows: [DayWindow] = []) -> Arrangement {
        let dayCount = max(prefs.days, 1)
        let places = dedupe(given)
        guard !places.isEmpty else {
            return Arrangement(days: Array(repeating: PlannedDay(stops: [], theme: "Free day"), count: dayCount),
                               leftOut: [])
        }

        // Compact areas, then fill the days by how much time each has.
        let capacities = (0..<dayCount).map { index in
            capacity(prefs: prefs, window: windows.indices.contains(index) ? windows[index] : DayWindow())
        }
        var buckets = distribute(places, dayCount: dayCount, capacities: capacities)

        func build(_ bucket: [PlanCandidate], dayIndex: Int) -> [PlannedStop] {
            let window = windows.indices.contains(dayIndex) ? windows[dayIndex] : DayWindow()
            let startMinute = max(prefs.dayStart.minutes, window.startMinute ?? 0)
            let limit = min(prefs.endLimitMinutes, window.endMinute ?? Int.max)

            let wanted = bucket.filter { $0.preferredMinute != nil }
            let flexible = bucket.filter { $0.preferredMinute == nil }

            // Short walking order, starting from the hotel when there is one.
            var order: [Int]
            if let anchor = window.anchor {
                order = RouteOptimizer.order([anchor] + flexible.map(\.coordinate)).dropFirst().map { $0 - 1 }
            } else {
                order = RouteOptimizer.order(flexible.map(\.coordinate))
            }
            let ordered = order.map { flexible[$0] }

            // Sights in walking order, then meals, cafés and nightlife where they belong in the day.
            var entries: [PlanEditor.Entry] = []
            for place in ordered where PlanEditor.slot(for: place, among: []) == .activity {
                entries.append((place, .activity))
            }
            for place in ordered where PlanEditor.slot(for: place, among: []) != .activity {
                let slot = PlanEditor.slot(for: place, among: entries)
                entries.insert((place, slot), at: min(PlanEditor.defaultIndex(for: slot, in: entries), entries.count))
            }

            var stops = schedule(entries.map { ($0.place, $0.slot) }, prefs: prefs, from: window.anchor,
                                 startMinute: startMinute, limit: limit)
            if !wanted.isEmpty {
                stops = insertTimed(wanted, into: stops, prefs: prefs, anchor: window.anchor,
                                    startMinute: startMinute, limit: limit)
            }
            return stops
        }

        var plans = buckets.indices.map { build(buckets[$0], dayIndex: $0) }

        // Whatever did not fit on its day goes to the day with the most room.
        var overflow: [PlanCandidate] = []
        for index in buckets.indices {
            let kept = Set(plans[index].map { $0.candidate.id })
            overflow += buckets[index].filter { !kept.contains($0.id) }
            buckets[index].removeAll { !kept.contains($0.id) }
        }
        var leftOut: [PlanCandidate] = []
        for place in overflow {
            var placed = false
            for index in plans.indices.sorted(by: { plans[$0].count < plans[$1].count }) {
                let attempt = build(buckets[index] + [place], dayIndex: index)
                if attempt.count == buckets[index].count + 1 {
                    buckets[index].append(place)
                    plans[index] = attempt
                    placed = true
                    break
                }
            }
            if !placed { leftOut.append(place) }
        }

        let days = plans.map { PlannedDay(stops: $0, theme: $0.isEmpty ? "Free day" : theme(for: $0)) }
        return Arrangement(days: days, leftOut: leftOut)
    }

    /// Puts places with a wanted time where they belong in the day, then schedules the day again
    /// (each of them waits for its time).
    static func insertTimed(_ places: [PlanCandidate],
                            into stops: [PlannedStop],
                            prefs: TripPreferences,
                            anchor: CLLocationCoordinate2D?,
                            startMinute: Int,
                            limit: Int,
                            travelOverride: TravelOverride? = nil) -> [PlannedStop] {
        var entries = stops.map { (place: $0.candidate, slot: $0.slot, key: $0.startMinute) }
        for place in places.sorted(by: { ($0.preferredMinute ?? 0) < ($1.preferredMinute ?? 0) }) {
            let wanted = place.preferredMinute ?? 0
            let position = entries.firstIndex { $0.key > wanted } ?? entries.count
            entries.insert((place, .activity, wanted), at: position)
        }
        return schedule(entries.map { ($0.place, $0.slot) }, prefs: prefs, from: anchor,
                        startMinute: startMinute, limit: limit, travelOverride: travelOverride)
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
                         limit: Int? = nil,
                         travelOverride: TravelOverride? = nil) -> [PlannedStop] {
        var result: [PlannedStop] = []
        var cursor = startMinute ?? prefs.dayStart.minutes
        var previous: CLLocationCoordinate2D? = anchor
        let limit = limit ?? prefs.endLimitMinutes

        for entry in slots {
            var start = cursor
            if let previous {
                let travel = travelOverride?(previous, entry.place.coordinate)
                    ?? travelMinutes(from: previous, to: entry.place.coordinate, transport: prefs.transport)
                start += travel + 5
            }
            start = (start + 4) / 5 * 5
            if let wanted = entry.place.preferredMinute {
                start = max(start, wanted)
            }
            // A late start (after a flight) leaves no room for a lunch at 5 pm.
            if entry.slot == .lunch && start > 15 * 60 { continue }
            switch entry.slot {
            case .lunch: start = max(start, 12 * 60 + 15)
            case .dinner: start = max(start, prefs.isFamily ? 18 * 60 : 18 * 60 + 45)
            case .nightlife: start = max(start, 20 * 60 + 30)
            default: break
            }
            if start >= limit { continue }

            let length = entry.place.fixedDuration ?? duration(for: entry.slot, kind: entry.place.kind)
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
        // The traveller's own places come first and are never dropped (two of them may even share a name);
        // other places are dropped when they duplicate one already kept.
        let ordered = candidates.sorted { a, b in
            if a.isMustSee != b.isMustSee { return a.isMustSee }
            return a.score > b.score
        }
        for candidate in ordered {
            if candidate.isMustSee {
                result.append(candidate)
                continue
            }
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
