import Foundation
import CoreLocation

/// One change to a planned day. Everything refers to places that already exist in the pool, so a
/// request (typed or from the AI) can never add a place that isn't real.
enum PlanEdit: Equatable {
    case remove(String)
    case replace(String, with: String)
    case add(String, after: String?)
    case setStart(Int)
}

struct EditOutcome {
    var day: PlannedDay
    /// Things the traveller should know, e.g. a stop that no longer fits.
    var notes: [String]
    var changed: Bool
}

/// Applies edits to one day and schedules it again. Pure logic, unit tested.
enum PlanEditor {
    typealias Entry = (place: PlanCandidate, slot: PlanSlot)

    static func apply(_ edits: [PlanEdit],
                      to day: PlannedDay,
                      pool: [PlanCandidate],
                      usedElsewhere: Set<String>,
                      prefs: TripPreferences,
                      window: DayWindow) -> EditOutcome {
        var entries: [Entry] = day.stops.map { ($0.candidate, $0.slot) }
        var start = day.startOverride
        var notes: [String] = []
        var changed = false
        var taken = usedElsewhere.union(entries.map { $0.place.id })

        for edit in edits {
            switch edit {
            case .remove(let id):
                guard let index = entries.firstIndex(where: { $0.place.id == id }) else {
                    notes.append("A stop to remove wasn't found.")
                    continue
                }
                taken.remove(id)
                entries.remove(at: index)
                changed = true

            case .replace(let id, let newID):
                guard let index = entries.firstIndex(where: { $0.place.id == id }),
                      let new = pool.first(where: { $0.id == newID }),
                      !taken.contains(newID) else {
                    notes.append("A replacement wasn't possible.")
                    continue
                }
                taken.remove(id)
                taken.insert(newID)
                var withoutOld = entries
                withoutOld.remove(at: index)
                entries[index] = (new, slot(for: new, among: withoutOld))
                changed = true

            case .add(let newID, let afterID):
                guard let new = pool.first(where: { $0.id == newID }), !taken.contains(newID) else {
                    notes.append("A place to add wasn't available.")
                    continue
                }
                taken.insert(newID)
                let newSlot = slot(for: new, among: entries)
                let index: Int
                if let afterID, let after = entries.firstIndex(where: { $0.place.id == afterID }) {
                    index = after + 1
                } else {
                    index = defaultIndex(for: newSlot, in: entries)
                }
                entries.insert((new, newSlot), at: min(index, entries.count))
                changed = true

            case .setStart(let minute):
                guard (4 * 60...14 * 60).contains(minute) else {
                    notes.append("That start time isn't sensible.")
                    continue
                }
                start = minute
                changed = true
            }
        }

        let stops = reschedule(entries, startOverride: start, prefs: prefs, window: window)
        if stops.count < entries.count {
            let dropped = entries.count - stops.count
            notes.append("\(dropped) \(dropped == 1 ? "stop" : "stops") no longer fit before the end of the day and \(dropped == 1 ? "was" : "were") left out.")
        }
        return EditOutcome(day: PlannedDay(stops: stops, theme: day.theme, startOverride: start),
                           notes: notes,
                           changed: changed)
    }

    /// Schedules stops again with the day's start and limits (flights, hotel, preferences).
    static func reschedule(_ entries: [Entry],
                           startOverride: Int?,
                           prefs: TripPreferences,
                           window: DayWindow) -> [PlannedStop] {
        let base = startOverride ?? prefs.dayStart.minutes
        return AutoPlanner.schedule(entries,
                                    prefs: prefs,
                                    from: window.anchor,
                                    startMinute: max(base, window.startMinute ?? 0),
                                    limit: min(prefs.endLimitMinutes, window.endMinute ?? Int.max))
    }

    /// The day starts earlier or later by `minutes`.
    static func shiftStart(_ day: PlannedDay, by minutes: Int, prefs: TripPreferences, window: DayWindow) -> EditOutcome {
        let current = day.startOverride ?? max(prefs.dayStart.minutes, window.startMinute ?? 0)
        let target = min(max(current + minutes, 6 * 60), 12 * 60)
        return apply([.setStart(target)], to: day, pool: [], usedElsewhere: [], prefs: prefs, window: window)
    }

    /// Other places that could take a stop's place: same kind, not used yet, close by and well rated.
    static func alternatives(for stop: PlannedStop,
                             pool: [PlanCandidate],
                             taken: Set<String>,
                             prefs: TripPreferences,
                             limit: Int = 8) -> [PlanCandidate] {
        let scale = prefs.transport.legScale
        func value(_ place: PlanCandidate) -> Double {
            let distance = RoutingService.straightLine(from: stop.candidate.coordinate, to: place.coordinate)
            return AutoPlanner.adjusted(place, prefs) / (1 + distance / scale)
        }
        return pool
            .filter { $0.kind == stop.candidate.kind && !taken.contains($0.id) }
            .sorted { value($0) > value($1) }
            .prefix(limit)
            .map { $0 }
    }

    /// A fresh version of one day from the places no other day uses.
    static func shuffle<G: RandomNumberGenerator>(_ day: PlannedDay,
                                                  pool: [PlanCandidate],
                                                  usedElsewhere: Set<String>,
                                                  prefs: TripPreferences,
                                                  window: DayWindow,
                                                  center: CLLocationCoordinate2D,
                                                  using rng: inout G) -> PlannedDay {
        var single = prefs
        single.days = 1
        let available = pool.filter { !usedElsewhere.contains($0.id) }
        let generated = AutoPlanner.generate(candidates: available,
                                             prefs: single,
                                             center: center,
                                             variation: 0.4,
                                             windows: [window],
                                             using: &rng)
        var result = generated.first ?? day
        result.theme = day.theme
        result.startOverride = nil
        return result
    }

    // MARK: Slots

    /// Which part of the day a place belongs to: a first food place is lunch, the next dinner.
    static func slot(for place: PlanCandidate, among entries: [Entry]) -> PlanSlot {
        switch place.kind {
        case .food: entries.contains { $0.slot == .lunch } ? .dinner : .lunch
        case .cafe: .cafe
        case .nightlife: .nightlife
        default: .activity
        }
    }

    /// Where a new stop goes when nobody said where: lunch in the middle of the sights, cafés and
    /// sights before dinner, nightlife last.
    static func defaultIndex(for slot: PlanSlot, in entries: [Entry]) -> Int {
        func firstIndex(of slots: [PlanSlot]) -> Int {
            entries.firstIndex { slots.contains($0.slot) } ?? entries.count
        }
        switch slot {
        case .activity: return firstIndex(of: [.cafe, .dinner, .nightlife])
        case .cafe: return firstIndex(of: [.dinner, .nightlife])
        case .dinner: return firstIndex(of: [.nightlife])
        case .nightlife: return entries.count
        case .lunch:
            let activities = entries.filter { $0.slot == .activity }.count
            let before = (activities + 1) / 2
            var seen = 0
            for (index, entry) in entries.enumerated() where entry.slot == .activity {
                seen += 1
                if seen == before { return index + 1 }
            }
            return 0
        }
    }
}
