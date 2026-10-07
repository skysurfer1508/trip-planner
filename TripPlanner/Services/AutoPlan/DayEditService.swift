import Foundation
import CoreLocation

/// Lets the traveller change one day by describing what they want. The AI only sees short ids for
/// the day's stops and for real places from the plan's pool, and can only answer with edits that
/// use those ids.
enum DayEditService {
    struct Prepared {
        var request: DayEditRequest
        var stopAliases: [String: String]
        var candidateAliases: [String: String]
    }

    struct Result {
        var summary: String
        var edits: [PlanEdit]
    }

    static func prepare(instruction: String,
                        day: PlannedDay,
                        dayNumber: Int,
                        pool: [PlanCandidate],
                        usedElsewhere: Set<String>,
                        prefs: TripPreferences,
                        destination: String,
                        window: DayWindow) -> Prepared {
        var stopAliases: [String: String] = [:]
        var stopItems: [DayEditItem] = []
        for (index, stop) in day.stops.enumerated() {
            let alias = "s\(index + 1)"
            stopAliases[alias] = stop.candidate.id
            stopItems.append(DayEditItem(alias: alias,
                                         name: stop.candidate.name,
                                         detail: "\(TripLogistics.timeText(stop.startMinute)), \(label(for: stop))"))
        }

        // Places near the day, a few of every kind so "more food" or "something outdoors" has options.
        let inDay = Set(day.stops.map(\.candidate.id))
        let center = center(of: day, fallback: window.anchor)
        var perKind: [DiscoverKind: Int] = [:]
        var candidateAliases: [String: String] = [:]
        var candidateItems: [DayEditItem] = []
        let ranked = pool
            .filter { !usedElsewhere.contains($0.id) && !inDay.contains($0.id) }
            .sorted { value($0, prefs, center) > value($1, prefs, center) }
        for place in ranked {
            guard candidateItems.count < 36, perKind[place.kind, default: 0] < 8 else { continue }
            perKind[place.kind, default: 0] += 1
            let alias = "p\(candidateItems.count + 1)"
            candidateAliases[alias] = place.id
            let distance = center.map { Format.distance(RoutingService.straightLine(from: $0, to: place.coordinate)) }
            candidateItems.append(DayEditItem(alias: alias,
                                              name: place.name,
                                              detail: [place.kind.title, distance.map { "\($0) away" }]
                                                  .compactMap { $0 }.joined(separator: ", ")))
        }

        let start = day.startOverride ?? max(prefs.dayStart.minutes, window.startMinute ?? 0)
        let request = DayEditRequest(instruction: instruction,
                                     dayNumber: dayNumber,
                                     destination: destination.isEmpty ? "the destination" : destination,
                                     travellers: describe(prefs),
                                     startTime: TripLogistics.timeText(start),
                                     stops: stopItems,
                                     candidates: candidateItems)
        return Prepared(request: request, stopAliases: stopAliases, candidateAliases: candidateAliases)
    }

    /// Turns the AI's commands into edits, dropping anything that uses an unknown id.
    static func edits(from response: DayEditResponse, prepared: Prepared) -> [PlanEdit] {
        response.commands.compactMap { command in
            switch command.action.lowercased() {
            case "remove":
                guard let id = prepared.stopAliases[command.stop] else { return nil }
                return .remove(id)
            case "replace":
                guard let id = prepared.stopAliases[command.stop],
                      let new = prepared.candidateAliases[command.candidate] else { return nil }
                return .replace(id, with: new)
            case "add":
                guard let new = prepared.candidateAliases[command.candidate] else { return nil }
                return .add(new, after: prepared.stopAliases[command.after])
            case "set_start":
                guard let minute = minutes(from: command.time) else { return nil }
                return .setStart(minute)
            default:
                return nil
            }
        }
    }

    static func minutes(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    // MARK: Helpers

    private static func label(for stop: PlannedStop) -> String {
        switch stop.slot {
        case .lunch: "lunch"
        case .dinner: "dinner"
        case .cafe: "café"
        case .nightlife: "nightlife"
        case .activity: stop.candidate.kind.title.lowercased()
        }
    }

    private static func center(of day: PlannedDay, fallback: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        let points = day.stops.map(\.candidate.coordinate)
        guard !points.isEmpty else { return fallback }
        let lat = points.reduce(0) { $0 + $1.latitude } / Double(points.count)
        let lon = points.reduce(0) { $0 + $1.longitude } / Double(points.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func value(_ place: PlanCandidate, _ prefs: TripPreferences, _ center: CLLocationCoordinate2D?) -> Double {
        let base = AutoPlanner.adjusted(place, prefs)
        guard let center else { return base }
        let distance = RoutingService.straightLine(from: center, to: place.coordinate)
        return base / (1 + distance / prefs.transport.legScale)
    }

    static func describe(_ prefs: TripPreferences) -> String {
        let interests = prefs.interests.map(\.title).sorted().joined(separator: ", ")
        return "\(prefs.group.title), \(prefs.travelers) \(prefs.travelers == 1 ? "person" : "people"), "
            + "\(prefs.pace.title.lowercased()) pace, \(prefs.transport.title.lowercased()), likes: \(interests)"
    }
}
