import Foundation

/// Google Gemini over REST (free tier with a key from Google AI Studio).
/// Uses the stable `generateContent` endpoint; if Google retires it, only this file changes.
struct GeminiAI: AIEngine {
    static let model = "gemini-2.5-flash"

    let apiKey: String
    var label: String { "Gemini" }

    func extractItinerary(text: String, context: AIContext) async throws -> ParsedItinerary {
        let prompt = AIPrompts.extract(text: String(text.prefix(60_000)), context: context)
        return ItineraryJSON.parse(try await generate(prompt: prompt, schema: AISchema.itinerary))
    }

    func dayThemes(_ days: [DayThemeInput], destination: String) async throws -> [String] {
        let json = try await generate(prompt: AIPrompts.themes(days, destination: destination), schema: AISchema.themes)
        return (json["themes"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func rankPicks(_ request: PicksRequest) async throws -> [AIPick] {
        let json = try await generate(prompt: AIPrompts.picks(request), schema: AISchema.picks)
        let rows = json["picks"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return AIPick(id: id, reason: row["reason"] as? String ?? "")
        }
    }

    func placeTips(name: String, city: String) async throws -> [String] {
        let json = try await generate(prompt: AIPrompts.tips(name: name, city: city), schema: AISchema.tips)
        return (json["tips"] as? [String] ?? []).filter { !$0.isEmpty }
    }

    // MARK: Request

    private func generate(prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent") else {
            throw AIError.badOutput
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "temperature": 0.3,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard let status = http?.statusCode, (200..<300).contains(status) else {
            if http?.statusCode == 429 { throw AIError.rateLimited }
            let message = (root?["error"] as? [String: Any])?["message"] as? String
            throw AIError.api(message ?? "status \(http?.statusCode ?? -1)")
        }

        guard let candidates = root?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              let payload = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw AIError.badOutput
        }
        return object
    }
}

/// Response schemas in Gemini's format.
enum AISchema {
    static func string(_ description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "STRING"]
        if let description { schema["description"] = description }
        return schema
    }

    static func choice(_ values: [String]) -> [String: Any] {
        ["type": "STRING", "enum": values]
    }

    static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "ARRAY", "items": items]
    }

    static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "OBJECT", "properties": properties, "required": required]
    }

    static let itinerary: [String: Any] = object([
        "days": array(object([
            "label": string("Heading of the day, e.g. Day 2"),
            "date": string("yyyy-MM-dd if known, otherwise empty"),
            "stops": array(object([
                "title": string("Name of the place or venue with the city, suitable for a map search"),
                "time": string("Start time HH:mm in 24 hour format, or empty"),
                "notes": string("Short useful note, or empty"),
                "category": choice(["sight", "food", "cafe", "hotel", "transport", "other"]),
            ], required: ["title"])),
        ], required: ["stops"])),
    ], required: ["days"])

    static let picks: [String: Any] = object([
        "picks": array(object([
            "id": string("The candidate id"),
            "reason": string("One sentence why it fits now"),
        ], required: ["id", "reason"])),
    ], required: ["picks"])

    static let themes: [String: Any] = object([
        "themes": array(string("Short day title, at most 4 words")),
    ], required: ["themes"])

    static let tips: [String: Any] = object([
        "tips": array(string("One short tip")),
    ], required: ["tips"])
}
