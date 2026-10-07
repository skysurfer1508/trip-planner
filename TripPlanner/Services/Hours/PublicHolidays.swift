import Foundation

struct Holiday: Codable, Equatable {
    var date: String          // yyyy-MM-dd
    var name: String
    var localName: String
    /// Only some regions of the country have the day off.
    var isRegional: Bool
}

/// Public holidays from Nager.Date (free, no key).
enum PublicHolidays {
    static func parse(_ rows: [[String: Any]]) -> [Holiday] {
        rows.compactMap { row in
            guard let date = row["date"] as? String,
                  let name = row["name"] as? String else { return nil }
            let types = row["types"] as? [String] ?? []
            guard types.isEmpty || types.contains("Public") else { return nil }
            let global = (row["global"] as? Bool) ?? true
            return Holiday(date: date, name: name, localName: (row["localName"] as? String) ?? name,
                           isRegional: !global)
        }
    }

    static func fetch(year: Int, country: String) async throws -> [Holiday] {
        guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(year)/\(country.uppercased())") else { return [] }
        return parse(try await Net.jsonArray(url: url, session: Net.cached))
    }

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func holiday(on date: Date, in list: [Holiday], calendar: Calendar = .current) -> Holiday? {
        let today = key(date, calendar: calendar)
        return list.first { $0.date == today }
    }
}
