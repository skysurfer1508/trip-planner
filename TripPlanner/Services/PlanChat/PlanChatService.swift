import Foundation
import SwiftData
import CoreLocation

/// Lets the traveller change the whole plan by describing what they want. The AI sees short ids for
/// the plan's stops and for real places nearby, and can only answer with edits that use those ids.
enum PlanChatService {
    struct Prepared {
        var request: PlanChatRequest
        var stops: [String: Stop]
        var places: [String: PlanCandidate]
    }

    @MainActor
    static func prepare(instruction: String, trip: Trip, pool: [PlanCandidate]) -> Prepared {
        var stops: [String: Stop] = [:]
        var days: [PlanChatDay] = []
        var count = 0
        var inTrip = Set<String>()

        for (index, day) in trip.sortedDays.enumerated() {
            var items: [DayEditItem] = []
            for stop in day.sortedStops where !ExistingStops.isLogistics(stop) {
                count += 1
                let alias = "s\(count)"
                stops[alias] = stop
                inTrip.insert(stop.name.lowercased())
                var detail: [String] = [stop.category.title.lowercased()]
                if let time = stop.plannedTime {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    detail.append(TripLogistics.timeText((parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
                }
                detail.append("\(stop.durationMinutes) min")
                items.append(DayEditItem(alias: alias, name: stop.name, detail: detail.joined(separator: ", ")))
            }

            let window = trip.window(for: day.date)
            var limits: [String] = []
            if let start = window.startMinute { limits.append("you are ready at \(TripLogistics.timeText(start)) after landing") }
            if let end = window.endMinute { limits.append("you must leave by \(TripLogistics.timeText(end))") }
            days.append(PlanChatDay(number: index + 1,
                                    title: day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                                    note: limits.joined(separator: ", "),
                                    stops: items))
        }

        // A few real places of each kind that are not in the plan yet.
        var places: [String: PlanCandidate] = [:]
        var placeItems: [DayEditItem] = []
        var perKind: [DiscoverKind: Int] = [:]
        let center = trip.destinationCoordinate
        for place in pool.sorted(by: { $0.score > $1.score }) where !inTrip.contains(place.name.lowercased()) {
            guard placeItems.count < 30, perKind[place.kind, default: 0] < 8 else { continue }
            perKind[place.kind, default: 0] += 1
            let alias = "p\(placeItems.count + 1)"
            places[alias] = place
            let away = center.map { Format.distance(RoutingService.straightLine(from: $0, to: place.coordinate)) + " from the centre" }
            placeItems.append(DayEditItem(alias: alias, name: place.name,
                                          detail: [place.kind.title, away].compactMap { $0 }.joined(separator: ", ")))
        }

        var travellers = "one traveller"
        if let data = trip.planPreferences, let prefs = try? JSONDecoder().decode(TripPreferences.self, from: data) {
            travellers = DayEditService.describe(prefs)
        }
        let request = PlanChatRequest(instruction: instruction,
                                      destination: trip.destination.isEmpty ? "the destination" : trip.destination,
                                      travellers: travellers,
                                      days: days,
                                      places: placeItems)
        return Prepared(request: request, stops: stops, places: places)
    }
}

/// A copy of every stop of a trip, to put the plan back after a change the traveller doesn't like.
struct TripSnapshot {
    var days: [[Stop]]

    @MainActor
    static func capture(_ trip: Trip) -> TripSnapshot {
        TripSnapshot(days: trip.sortedDays.map { day in
            day.sortedStops.map { stop in
                let copy = stop.clone()
                copy.isDone = stop.isDone
                return copy
            }
        })
    }

    @MainActor
    func restore(into trip: Trip) {
        for (index, day) in trip.sortedDays.enumerated() {
            for stop in Array(day.stops) {
                trip.modelContext?.delete(stop)
            }
            guard days.indices.contains(index) else { continue }
            for stop in days[index] {
                day.append(stop)
            }
        }
    }
}

/// Carries out the AI's edits on the trip's real days and stops.
enum PlanChatApplier {
    struct Outcome {
        var changes: [String] = []
        var notes: [String] = []
        var changed: Bool { !changes.isEmpty }
    }

    @MainActor
    static func apply(_ commands: [PlanChatCommand],
                      trip: Trip,
                      stops: [String: Stop],
                      places: [String: PlanCandidate]) -> Outcome {
        var outcome = Outcome()
        let days = trip.sortedDays
        let calendar = Calendar.current
        var retimed: [Day] = []

        func day(_ number: Int?) -> Day? {
            guard let number, days.indices.contains(number - 1) else { return nil }
            return days[number - 1]
        }
        func live(_ alias: String) -> Stop? {
            guard let stop = stops[alias], stop.modelContext != nil, stop.day != nil else { return nil }
            return stop
        }
        func minute(of time: String) -> Int? { DayEditService.minutes(from: time) }
        func date(on day: Day, minute: Int) -> Date? {
            calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day.date)
        }
        /// Puts `stop` in `target` after `anchor` ("first" = at the start, nil = at the end).
        func position(_ stop: Stop, in target: Day, after anchor: String) {
            var ordered = target.sortedStops.filter { $0 !== stop }
            if anchor.lowercased() == "first" {
                ordered.insert(stop, at: 0)
            } else if let other = stops[anchor], let index = ordered.firstIndex(where: { $0 === other }) {
                ordered.insert(stop, at: index + 1)
            } else {
                ordered.append(stop)
            }
            target.renumber(ordered)
        }
        func number(of day: Day) -> Int {
            (days.firstIndex { $0 === day } ?? 0) + 1
        }
        func without(_ list: [Stop], _ excluded: [Stop]) -> [Stop] {
            list.filter { stop in !excluded.contains { $0 === stop } }
        }
        func shiftable(_ day: Day) -> [Stop] {
            day.sortedStops.filter { !ExistingStops.isLogistics($0) }
        }

        for command in commands {
            switch command.action.lowercased() {
            case "remove":
                guard let stop = live(command.stop), let owner = stop.day else {
                    outcome.notes.append("A stop to remove wasn't found.")
                    continue
                }
                let name = stop.name
                owner.renumber(owner.sortedStops.filter { $0 !== stop })
                trip.modelContext?.delete(stop)
                outcome.changes.append("Removed \(name)")

            case "move":
                guard let stop = live(command.stop), let source = stop.day else {
                    outcome.notes.append("A stop to move wasn't found.")
                    continue
                }
                let target = day(command.day) ?? source
                if target !== source { source.move(stop, to: target) }
                position(stop, in: target, after: command.after)
                outcome.changes.append("Moved \(stop.name) to day \(number(of: target))")

            case "set_time":
                guard let stop = live(command.stop), let owner = stop.day, let wanted = minute(of: command.time),
                      let time = date(on: owner, minute: wanted) else {
                    outcome.notes.append("A time couldn't be set.")
                    continue
                }
                stop.plannedTime = time
                if !retimed.contains(where: { $0 === owner }) { retimed.append(owner) }
                outcome.changes.append("\(stop.name) at \(TripLogistics.timeText(wanted))")

            case "shift_day":
                guard let delta = Int(command.time.replacingOccurrences(of: "+", with: "")), delta != 0 else {
                    outcome.notes.append("A shift needs a number of minutes.")
                    continue
                }
                let targets = (command.day ?? 0) == 0 ? days : [day(command.day)].compactMap { $0 }
                var moved = 0
                for target in targets {
                    for stop in shiftable(target) {
                        guard let time = stop.plannedTime else { continue }
                        stop.plannedTime = time.addingTimeInterval(TimeInterval(delta * 60))
                        moved += 1
                    }
                }
                if moved > 0 {
                    outcome.changes.append("Moved \(moved) \(moved == 1 ? "stop" : "stops") \(abs(delta)) min \(delta > 0 ? "later" : "earlier")")
                } else {
                    outcome.notes.append("There were no times to shift.")
                }

            case "swap_days":
                guard let first = day(command.day), let second = day(command.otherDay), first !== second else {
                    outcome.notes.append("Two different days are needed to swap them.")
                    continue
                }
                let firstStops = shiftable(first)
                let secondStops = shiftable(second)
                for stop in firstStops {
                    stop.day = second
                    if let time = stop.plannedTime { stop.plannedTime = second.combine(time: time) }
                }
                for stop in secondStops {
                    stop.day = first
                    if let time = stop.plannedTime { stop.plannedTime = first.combine(time: time) }
                }
                let kept = firstStops + secondStops
                first.renumber(secondStops + without(first.sortedStops, kept))
                second.renumber(firstStops + without(second.sortedStops, kept))
                outcome.changes.append("Swapped day \(number(of: first)) and day \(number(of: second))")

            case "retime":
                guard let target = day(command.day) else {
                    outcome.notes.append("A day to re-time wasn't found.")
                    continue
                }
                TimeAdjuster.adjust(target)
                outcome.changes.append("Adjusted the times of day \(number(of: target))")

            case "add":
                guard let place = places[command.place] else {
                    outcome.notes.append("A place to add wasn't available.")
                    continue
                }
                let target = day(command.day) ?? days.first
                guard let target else { continue }
                let stop = Stop(name: place.name, latitude: place.coordinate.latitude,
                                longitude: place.coordinate.longitude, address: place.address,
                                category: place.kind.stopCategory)
                target.append(stop)
                if let wanted = minute(of: command.time) { stop.plannedTime = date(on: target, minute: wanted) }
                position(stop, in: target, after: command.after)
                if !retimed.contains(where: { $0 === target }) { retimed.append(target) }
                outcome.changes.append("Added \(place.name) to day \(number(of: target))")

            case "replace":
                guard let old = live(command.stop), let owner = old.day, let place = places[command.place] else {
                    outcome.notes.append("A replacement wasn't possible.")
                    continue
                }
                let new = Stop(name: place.name, latitude: place.coordinate.latitude,
                               longitude: place.coordinate.longitude, address: place.address,
                               category: place.kind.stopCategory)
                new.plannedTime = old.plannedTime
                new.durationMinutes = old.durationMinutes
                owner.append(new)
                let ordered = owner.sortedStops.filter { $0 !== new }.map { $0 === old ? new : $0 }
                owner.renumber(ordered)
                outcome.changes.append("Replaced \(old.name) with \(place.name)")
                trip.modelContext?.delete(old)

            default:
                outcome.notes.append("Skipped something I didn't understand.")
            }
        }

        // A day where every stop has a time stays in time order.
        for target in retimed where target.modelContext != nil {
            let remaining = target.stops
            if !remaining.isEmpty, remaining.allSatisfy({ $0.plannedTime != nil }) {
                target.sortByTime()
            }
        }
        return outcome
    }
}
