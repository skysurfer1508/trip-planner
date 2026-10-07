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

/// Turns Gemini's answer to a day-edit request into commands.
enum DayEditJSON {
    static func parse(_ root: [String: Any]) -> DayEditResponse {
        let rows = root["edits"] as? [[String: Any]] ?? []
        let commands = rows.compactMap { row -> DayEditCommand? in
            guard let action = row["action"] as? String, !action.isEmpty else { return nil }
            return DayEditCommand(action: action,
                                  stop: row["stop"] as? String ?? "",
                                  candidate: row["candidate"] as? String ?? "",
                                  after: row["after"] as? String ?? "",
                                  time: row["time"] as? String ?? "")
        }
        return DayEditResponse(summary: (root["summary"] as? String) ?? "", commands: commands)
    }
}

/// Turns the answer to the "places in this text" request into `PlaceWish`es.
enum PlaceWishJSON {
    static func parse(_ root: [String: Any]) -> [PlaceWish] {
        let rows = root["places"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var result: [PlaceWish] = []
        for row in rows {
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), name.count >= 2 else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            var wish = PlaceWish(name: name)
            let local = (row["localName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !local.isEmpty, local.lowercased() != key { wish.alternativeNames = [local] }
            wish.kind = (row["kind"] as? String).flatMap { ["sight", "food", "cafe", "nightlife", "other"].contains($0) ? $0 : nil } ?? "sight"
            wish.statedMinute = minute(row["statedTime"] as? String)
            if wish.statedMinute == nil {
                wish.suggestedMinute = minute(row["bestTime"] as? String)
            }
            if let day = (row["day"] as? String).flatMap({ Int($0.filter(\.isNumber)) }), day > 0 { wish.day = day }
            result.append(wish)
        }
        return result
    }

    /// "18:30" -> 1110.
    static func minute(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0].filter(\.isNumber)), let minute = Int(parts[1].filter(\.isNumber).prefix(2)),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

/// Turns the AI's answer to a whole-plan change request into commands.
enum PlanChatJSON {
    static func parse(_ root: [String: Any]) -> PlanChatResponse {
        func number(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let text = value as? String { return Int(text.filter { $0.isNumber }) }
            return nil
        }
        let rows = root["edits"] as? [[String: Any]] ?? []
        let commands = rows.compactMap { row -> PlanChatCommand? in
            guard let action = row["action"] as? String, !action.isEmpty else { return nil }
            return PlanChatCommand(action: action,
                                   stop: row["stop"] as? String ?? "",
                                   place: row["place"] as? String ?? "",
                                   after: row["after"] as? String ?? "",
                                   day: number(row["day"]),
                                   otherDay: number(row["otherDay"]),
                                   time: row["time"] as? String ?? "")
        }
        return PlanChatResponse(summary: (root["summary"] as? String) ?? "", commands: commands)
    }
}
