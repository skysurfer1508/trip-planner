import Foundation

enum ClaudeError: LocalizedError {
    case api(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .api(let message): "Claude: \(message)"
        case .badOutput: "Claude returned something unexpected."
        }
    }
}

/// Uses the Anthropic API to read any itinerary layout. Only called when the user chooses
/// "Claude" for an import; the document text is sent to Anthropic in that case.
enum ClaudeItineraryService {
    static let model = "claude-haiku-4-5-20251001"

    static func parse(text: String,
                      destination: String,
                      dates: String,
                      apiKey: String) async throws -> ParsedItinerary {
        let stopSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string",
                          "description": "Name of the place or venue, with the city if the document gives it, so it can be found on a map."],
                "time": ["type": "string", "description": "Start time as HH:mm (24h) if the document gives one."],
                "notes": ["type": "string", "description": "Useful details such as tickets or reservation hints."],
                "category": ["type": "string", "enum": ["sight", "food", "cafe", "hotel", "transport", "other"]],
            ],
            "required": ["title"],
        ]
        let daySchema: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "Heading of the day as written, e.g. 'Day 2'."],
                "date": ["type": "string", "description": "yyyy-MM-dd if the document gives the date."],
                "stops": ["type": "array", "items": stopSchema],
            ],
            "required": ["stops"],
        ]
        let tool: [String: Any] = [
            "name": "save_itinerary",
            "description": "Save the day-by-day program extracted from the document.",
            "input_schema": [
                "type": "object",
                "properties": ["days": ["type": "array", "items": daySchema]],
                "required": ["days"],
            ],
        ]

        let prompt = """
        Extract the day-by-day travel program from the document below. Include only things a traveller \
        would go to or do at a specific place (sights, meals, hotels, stations). Leave out prices, booking \
        numbers, general notes and advertising. Keep names in the document's language. \
        Trip destination: \(destination.isEmpty ? "unknown" : destination). Trip dates: \(dates).

        DOCUMENT:
        \(String(text.prefix(60_000)))
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "save_itinerary"],
            "messages": [["role": "user", "content": prompt]],
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw ClaudeError.badOutput }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "request failed"
            throw ClaudeError.api(message)
        }
        guard let content = json?["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let rawDays = input["days"] as? [[String: Any]] else {
            throw ClaudeError.badOutput
        }
        return ParsedItinerary(days: rawDays.map(mapDay))
    }

    private static func mapDay(_ raw: [String: Any]) -> ParsedDay {
        var day = ParsedDay(label: raw["label"] as? String, date: nil)
        if let string = raw["date"] as? String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            day.date = formatter.date(from: string)
        }
        for rawStop in raw["stops"] as? [[String: Any]] ?? [] {
            guard let title = rawStop["title"] as? String, !title.isEmpty else { continue }
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
