import Foundation

/// Turns the JSON an AI engine returns into the app's `ParsedItinerary`.
enum ItineraryJSON {
    static func parse(_ root: [String: Any]) -> ParsedItinerary {
        let rawDays = root["days"] as? [[String: Any]] ?? []
        return ParsedItinerary(days: rawDays.map(mapDay).filter { !$0.stops.isEmpty })
    }

    private static func mapDay(_ raw: [String: Any]) -> ParsedDay {
        let label = (raw["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var day = ParsedDay(label: label, date: nil)

        if let string = raw["date"] as? String, !string.isEmpty {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            day.date = formatter.date(from: string)
        }

        for rawStop in raw["stops"] as? [[String: Any]] ?? [] {
            guard let title = (rawStop["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { continue }
            var stop = ParsedStop(title: title)
            if let time = rawStop["time"] as? String {
                let parts = time.split(separator: ":")
                if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)),
                   (0..<24).contains(h), (0..<60).contains(m) {
                    stop.hour = h
                    stop.minute = m
                }
            }
            stop.notes = rawStop["notes"] as? String ?? ""
            stop.category = (rawStop["category"] as? String).flatMap { StopCategory(rawValue: $0) } ?? .other
            day.stops.append(stop)
        }
        return day
    }
}

/// Splits long text into pieces for engines with a small context window, preferring to break
/// at "Day N" headings.
enum TextChunker {
    static func chunks(_ text: String, limit: Int = 2500) -> [String] {
        var pieces: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var rest = Substring(line)
            while rest.count > limit {
                pieces.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            pieces.append(String(rest))
        }

        var result: [String] = []
        var current = ""
        for piece in pieces {
            let isHeader = piece.range(of: #"^\s*(day|tag)\s*\d+"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
            let tooLong = current.count + piece.count + 1 > limit
            if !current.isEmpty && (tooLong || (isHeader && current.count > limit / 2)) {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + piece
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }
}
