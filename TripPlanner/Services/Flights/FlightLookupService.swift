import Foundation
import CoreLocation
import MapKit

struct FlightAirport {
    var iata: String?
    var name: String
    var city: String?
    var coordinate: CLLocationCoordinate2D?
    var countryCode: String?

    /// "Lisbon Humberto Delgado (LIS)"
    var displayName: String {
        guard let iata, !iata.isEmpty else { return name }
        return name.contains(iata) ? name : "\(name) (\(iata))"
    }

    /// "Lisbon (LIS)"
    var shortName: String {
        let base = city ?? name
        guard let iata, !iata.isEmpty else { return base }
        return "\(base) (\(iata))"
    }
}

struct FlightLeg: Identifiable {
    let id = UUID()
    var number: String
    var airline: String?
    var from: FlightAirport
    var to: FlightAirport
    /// Local clock times as printed on the ticket (wall-clock time at each airport).
    var departure: Date
    var arrival: Date
    var departureTerminal: String?
    var arrivalTerminal: String?
    var status: String?

    var isInternational: Bool {
        guard let a = from.countryCode, let b = to.countryCode else { return true }
        return a != b
    }
}

enum FlightLookupError: LocalizedError {
    case noKey
    case invalidNumber
    case notFound
    case rateLimited
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your free flight data key in Settings to look flights up."
        case .invalidNumber: "Enter a flight number like LH 1234."
        case .notFound: "No flight found for that number and date. Schedules for dates far ahead may not be published yet; you can enter the times by hand."
        case .rateLimited: "The free flight lookup limit for this month is used up. Enter the times by hand."
        case .api(let message): "Flight lookup failed: \(message)"
        }
    }
}

/// Looks a flight up by number and date with AeroDataBox (free plan on RapidAPI). It returns the
/// airports and the scheduled local times, so only the flight number and date have to be typed.
enum FlightLookupService {
    static let host = "aerodatabox.p.rapidapi.com"

    /// "lh 1234" -> "LH1234". Nil if it doesn't look like a flight number.
    static func normalize(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.range(of: #"^[A-Z0-9]{2}\d{1,4}[A-Z]?$"#, options: .regularExpression) != nil else { return nil }
        return cleaned
    }

    static func lookup(number: String, date: Date, key: String) async throws -> [FlightLeg] {
        guard !key.isEmpty else { throw FlightLookupError.noKey }
        guard let flight = normalize(number) else { throw FlightLookupError.invalidNumber }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        guard var components = URLComponents(string: "https://\(host)/flights/number/\(flight)/\(formatter.string(from: date))") else {
            throw FlightLookupError.invalidNumber
        }
        components.queryItems = [
            URLQueryItem(name: "dateLocalRole", value: "Both"),
            URLQueryItem(name: "withAircraftImage", value: "false"),
            URLQueryItem(name: "withLocation", value: "false"),
        ]
        guard let url = components.url else { throw FlightLookupError.invalidNumber }

        do {
            let rows = try await Net.jsonArray(url: url,
                                               headers: ["X-RapidAPI-Key": key, "X-RapidAPI-Host": host],
                                               session: Net.cached)
            let legs = parse(rows)
            if legs.isEmpty { throw FlightLookupError.notFound }
            return legs
        } catch let error as NetError {
            switch error {
            case .badStatus(404): throw FlightLookupError.notFound
            case .badStatus(401), .badStatus(403): throw FlightLookupError.api("the key was rejected. Check it in Settings.")
            case .badStatus(429): throw FlightLookupError.rateLimited
            default: throw FlightLookupError.api(error.localizedDescription)
            }
        }
    }

    // MARK: Parsing

    static func parse(_ rows: [[String: Any]]) -> [FlightLeg] {
        rows.compactMap { row in
            guard let departure = row["departure"] as? [String: Any],
                  let arrival = row["arrival"] as? [String: Any],
                  let from = airport(departure["airport"]),
                  let to = airport(arrival["airport"]),
                  let departureTime = localTime(departure),
                  let arrivalTime = localTime(arrival) else { return nil }

            return FlightLeg(number: (row["number"] as? String) ?? "",
                             airline: (row["airline"] as? [String: Any])?["name"] as? String,
                             from: from,
                             to: to,
                             departure: departureTime,
                             arrival: arrivalTime,
                             departureTerminal: departure["terminal"] as? String,
                             arrivalTerminal: arrival["terminal"] as? String,
                             status: row["status"] as? String)
        }
    }

    private static func airport(_ value: Any?) -> FlightAirport? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let name = (dictionary["name"] as? String) ?? (dictionary["shortName"] as? String) ?? "Airport"
        var coordinate: CLLocationCoordinate2D?
        if let location = dictionary["location"] as? [String: Any],
           let lat = Net.double(location["lat"]), let lon = Net.double(location["lon"]) {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return FlightAirport(iata: dictionary["iata"] as? String,
                             name: name,
                             city: dictionary["municipalityName"] as? String,
                             coordinate: coordinate,
                             countryCode: dictionary["countryCode"] as? String)
    }

    /// Reads the scheduled local time, e.g. "2026-06-05 10:00+02:00", as the wall-clock time printed
    /// on the ticket.
    private static func localTime(_ side: [String: Any]) -> Date? {
        let candidates: [String?] = [
            (side["scheduledTime"] as? [String: Any])?["local"] as? String,
            side["scheduledTimeLocal"] as? String,
            (side["revisedTime"] as? [String: Any])?["local"] as? String,
        ]
        guard let text = candidates.compactMap({ $0 }).first, text.count >= 16 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: String(text.prefix(16)).replacingOccurrences(of: "T", with: " "))
    }

    // MARK: Choosing and helpers

    /// A number can cover several legs (A → B → C). Pick the one that touches the destination:
    /// the leg landing there for an arrival flight, the leg leaving from there for a flight home.
    static func bestLeg(_ legs: [FlightLeg], kind: BookingKind, near destination: CLLocationCoordinate2D?) -> FlightLeg? {
        guard let destination else { return legs.first }
        func distance(_ airport: FlightAirport) -> Double {
            guard let coordinate = airport.coordinate else { return .infinity }
            return RoutingService.straightLine(from: coordinate, to: destination)
        }
        let ranked = legs.sorted {
            distance(kind == .arrivalFlight ? $0.to : $0.from) < distance(kind == .arrivalFlight ? $1.to : $1.from)
        }
        return ranked.first
    }

    /// Time needed around the flight, a little shorter for domestic ones.
    static func defaultBuffer(kind: BookingKind, leg: FlightLeg) -> Int {
        switch kind {
        case .arrivalFlight: leg.isInternational ? 120 : 90
        case .departureFlight: leg.isInternational ? 180 : 120
        case .hotel: 0
        }
    }

    /// Airports without coordinates in the response are looked up in Apple Maps.
    static func coordinate(for airport: FlightAirport) async -> CLLocationCoordinate2D? {
        if let existing = airport.coordinate { return existing }
        let query = airport.iata.map { "\($0) airport" } ?? airport.name
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        return try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
    }
}
