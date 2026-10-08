import Foundation
import CoreLocation

/// Live data from Transitous: a fresh look at one journey, and the departure board of a stop. Real-time
/// positions come from the transit agencies' own feeds; where an agency sends none, times are the timetable's.
enum TransitLive {
    /// One line of a departure board.
    struct Departure: Identifiable, Equatable {
        var id: String
        var mode: TransitMode
        var line: String?
        var headsign: String?
        var colorHex: String?
        /// The live time when there is live data, else the timetable's.
        var departure: Date
        var scheduled: Date?
        var realTime: Bool
        var cancelled: Bool
        var tripId: String?

        var delayMinutes: Int? {
            guard realTime, let scheduled else { return nil }
            return Int((departure.timeIntervalSince(scheduled) / 60).rounded())
        }
    }

    // MARK: Refreshing one journey

    /// ids contain "/", "+" and "=", and "+" would be read as a space: every character that isn't plain is escaped.
    static func escape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func refreshURL(itineraryId: String) -> URL? {
        URL(string: "\(TransitousService.baseURL)/api/v6/refresh-itinerary?itineraryId=\(escape(itineraryId))&detailedLegs=true")
    }

    /// The same journey with the latest live times. Nil when the service no longer knows the journey
    /// (then the caller searches again).
    static func refresh(_ itinerary: TransitItinerary) async throws -> TransitItinerary? {
        guard let id = itinerary.id, let url = refreshURL(itineraryId: id) else { return nil }
        try await TransitNetwork.shared.enter()
        do {
            let json = try await Net.json(url: url, headers: ["User-Agent": TransitousService.userAgent])
            await TransitNetwork.shared.leave()
            return TransitousService.parseItinerary(json)
        } catch NetError.badStatus(let code) where code == 404 || code == 400 || code == 422 {
            await TransitNetwork.shared.leave()
            return nil
        } catch {
            await TransitNetwork.shared.leave()
            await TransitNetwork.shared.note(error)
            throw error
        }
    }

    // MARK: Departure board

    static func departuresURL(stopId: String, at date: Date, count: Int) -> URL? {
        URL(string: "\(TransitousService.baseURL)/api/v6/stoptimes?stopId=\(escape(stopId))&n=\(count)&time=\(escape(TransitTime.requestString(date)))")
    }

    static func departures(stopId: String, from date: Date = Date(), count: Int = 10) async throws -> [Departure] {
        guard let url = departuresURL(stopId: stopId, at: date, count: count) else { return [] }
        try await TransitNetwork.shared.enter()
        do {
            let json = try await Net.json(url: url, headers: ["User-Agent": TransitousService.userAgent])
            await TransitNetwork.shared.leave()
            return parseDepartures(json)
        } catch {
            await TransitNetwork.shared.leave()
            await TransitNetwork.shared.note(error)
            throw error
        }
    }

    static func parseDepartures(_ json: [String: Any]) -> [Departure] {
        let rows = json["stopTimes"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let place = row["place"] as? [String: Any],
                  let departure = TransitTime.parse((place["departure"] as? String) ?? (place["scheduledDeparture"] as? String))
            else { return nil }
            let tripId = row["tripId"] as? String
            let color = (row["routeColor"] as? String)?.replacingOccurrences(of: "#", with: "")
            let scheduled = TransitTime.parse(place["scheduledDeparture"] as? String)
            let line = (row["routeShortName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let headsign = (row["headsign"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Departure(id: "\(tripId ?? UUID().uuidString)@\(Int(departure.timeIntervalSince1970))",
                             mode: TransitMode(motis: (row["mode"] as? String) ?? "OTHER"),
                             line: line,
                             headsign: headsign,
                             colorHex: (color?.count == 6) ? color : nil,
                             departure: departure,
                             scheduled: scheduled,
                             realTime: (row["realTime"] as? Bool) ?? false,
                             cancelled: (row["cancelled"] as? Bool) ?? (place["cancelled"] as? Bool) ?? false,
                             tripId: tripId)
        }
        .sorted { $0.departure < $1.departure }
    }

    // MARK: Leaving on time

    /// When to leave to catch the first vehicle: its (live) departure, less the walk to the stop and a
    /// buffer. Nil for a walk-only route.
    static func leaveBy(_ itinerary: TransitItinerary, bufferSeconds: TimeInterval = 120) -> Date? {
        guard let first = itinerary.transitLegs.first, let departure = first.departure else { return nil }
        var walk: TimeInterval = 0
        for leg in itinerary.legs {
            if leg.isWalking {
                walk += TimeInterval(leg.duration)
            } else {
                break
            }
        }
        return departure.addingTimeInterval(-(walk + bufferSeconds))
    }

    /// "in 4 min", "now", "left 2 min ago".
    static func countdownText(until date: Date, now: Date = Date()) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.down))
        if minutes > 0 { return "in \(Format.minutes(minutes))" }
        if minutes == 0 { return "now" }
        return "left \(Format.minutes(-minutes)) ago"
    }
}
