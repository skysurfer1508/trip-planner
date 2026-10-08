import Foundation

/// Google Gemini over REST (free tier with a key from Google AI Studio).
/// Uses the stable `generateContent` endpoint; if Google retires it, only this file changes.
struct GeminiAI: AIEngine {
    static let model = "gemini-3.8-flash"

    let apiKey: String
    var label: String { "Gemini" }

    func extractItinerary(text: String, context: AIContext) async throws -> ParsedItinerary {
        let prompt = AIPrompts.extract(text: String(text.prefix(60_000)), context: context)
        return ItineraryJSON.parse(try await generate(prompt: prompt, schema: AISchema.itinerary))
    }

    func extractPlaces(text: String, destination: String) async throws -> [PlaceWish] {
        let prompt = AIPrompts.places(text: String(text.prefix(20_000)), destination: destination)
        return PlaceWishJSON.parse(try await generate(prompt: prompt, schema: AISchema.places))
    }

    func dayThemes(_ days: [DayThemeInput], destination: String) async throws -> [String] {
        let json = try await generate(prompt: AIPrompts.themes(days, destination: destination), schema: AISchema.themes)
        return (json["themes"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func editPlan(_ request: PlanChatRequest) async throws -> PlanChatResponse {
        PlanChatJSON.parse(try await generate(prompt: AIPrompts.editPlan(request), schema: AISchema.planEdit))
    }

    func editDay(_ request: DayEditRequest) async throws -> DayEditResponse {
        let json = try await generate(prompt: AIPrompts.editDay(request), schema: AISchema.dayEdit)
        return DayEditJSON.parse(json)
    }

    func summarizeTransit(text: String, city: String) async throws -> TransitNotes {
        let json = try await generate(prompt: AIPrompts.transit(text: String(text.prefix(6_000)), city: city),
                                      schema: AISchema.transitNotes)
        func list(_ key: String) -> [String] { (json[key] as? [String] ?? []).filter { !$0.isEmpty } }
        return TransitNotes(tickets: list("tickets"), apps: list("apps"), tips: list("tips"))
    }

    func summarizePractical(text: String, country: String) async throws -> PracticalNotes {
        let json = try await generate(prompt: AIPrompts.practical(text: String(text.prefix(7_000)), country: country),
                                      schema: AISchema.practical)
        func list(_ key: String) -> [String] { (json[key] as? [String] ?? []).filter { !$0.isEmpty } }
        return PracticalNotes(emergency: list("emergency"), safety: list("safety"), money: list("money"),
                              connectivity: list("connectivity"), electricity: list("electricity"),
                              health: list("health"), etiquette: list("etiquette"))
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
            let message = (root?["error"] as? [String: Any])?["message"] as? String
            var detail = "status \(http?.statusCode ?? -1)"
            if let message { detail += ": \(message)" }
            Diagnostics.shared.record(service: "generativelanguage.googleapis.com", message: detail)
            if http?.statusCode == 429 { throw AIError.rateLimited }
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

/// The outcome of a connection test for the Settings screen.
struct GeminiCheck: Equatable {
    var ok: Bool
    var message: String
}

extension GeminiAI {
    /// Sends one tiny request to find out whether the key works, and says what is wrong if it doesn't.
    func check() async -> GeminiCheck {
        let started = Date()
        let schema = AISchema.object(["reply": AISchema.string("The word OK")], required: ["reply"])
        do {
            _ = try await generate(prompt: "Reply with the single word OK.", schema: schema)
            let seconds = Date().timeIntervalSince(started)
            return GeminiCheck(ok: true, message: "Works. \(Self.model) answered in \(String(format: "%.1f", seconds)) s.")
        } catch {
            return GeminiCheck(ok: false, message: Self.explain(error))
        }
    }

    /// A plain-language reason and what to do about it.
    static func explain(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection. Connect and try again."
            case .timedOut:
                return "Gemini didn't answer in time. Try again in a moment."
            default:
                return "Couldn't reach Gemini (\(url.localizedDescription))."
            }
        }
        if let ai = error as? AIError {
            switch ai {
            case .rateLimited:
                return "The key works, but the free limit is used up for now (or too many requests in a minute). Try again soon."
            case .badOutput:
                return "Gemini answered, but not in the expected format. The model may have changed."
            case .unavailable:
                return ai.localizedDescription
            case .api(let message):
                let lower = message.lowercased()
                if lower.contains("api key not valid") || lower.contains("api_key_invalid") || lower.contains("key not found") {
                    return "Google rejected this key. Copy it again from AI Studio (aistudio.google.com/apikey) without spaces."
                }
                if lower.contains("permission") || lower.contains("403") || lower.contains("not enabled") {
                    return "The key is not allowed to use Gemini. Create a new key in AI Studio, or enable the Generative Language API for it."
                }
                if lower.contains("not found") || lower.contains("404") {
                    return "The model \(model) wasn't found. Google may have retired it, the app needs an update. (\(message))"
                }
                if lower.contains("location") || lower.contains("not supported") {
                    return "Gemini isn't available for this account or region. (\(message))"
                }
                return "Gemini answered with an error: \(message)"
            }
        }
        return error.localizedDescription
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

    static let places: [String: Any] = object([
        "places": array(object([
            "name": string("Proper name of the place as on a map"),
            "localName": string("Local-language name if different, else empty"),
            "kind": choice(["sight", "food", "cafe", "nightlife", "other"]),
            "statedTime": string("HH:mm if the text says when to go, else empty"),
            "bestTime": string("HH:mm best time to visit when no time is stated"),
            "day": string("Day number only if stated, else empty"),
        ], required: ["name", "kind"])),
    ], required: ["places"])

    static let picks: [String: Any] = object([
        "picks": array(object([
            "id": string("The candidate id"),
            "reason": string("One sentence why it fits now"),
        ], required: ["id", "reason"])),
    ], required: ["picks"])

    static let planEdit: [String: Any] = object([
        "summary": string("One or two short sentences about what changed, or why nothing could change"),
        "edits": array(object([
            "action": choice(["remove", "move", "set_time", "shift_day", "swap_days", "retime", "add", "replace"]),
            "stop": string("An s-id, or empty"),
            "place": string("A p-id, or empty"),
            "after": string("An s-id, first, or empty"),
            "day": string("A day number, or empty"),
            "otherDay": string("A second day number for swap_days, or empty"),
            "time": string("HH:mm, or minutes like +60, or empty"),
        ], required: ["action"])),
    ], required: ["summary", "edits"])

    static let dayEdit: [String: Any] = object([
        "summary": string("One short sentence about what changed, or why nothing could change"),
        "edits": array(object([
            "action": choice(["remove", "replace", "add", "set_start"]),
            "stop": string("An s-id from the current stops, or empty"),
            "candidate": string("A p-id from the places list, or empty"),
            "after": string("An s-id to insert after, or empty"),
            "time": string("HH:mm for set_start, or empty"),
        ], required: ["action"])),
    ], required: ["summary", "edits"])

    static let transitNotes: [String: Any] = object([
        "tickets": array(string("A short note about tickets or passes")),
        "apps": array(string("A short note about an app or website")),
        "tips": array(string("A short practical tip")),
    ], required: ["tickets", "apps", "tips"])

    static let practical: [String: Any] = object([
        "emergency": array(string("Emergency number or who to call")),
        "safety": array(string("A safety note")),
        "money": array(string("A money or tipping note")),
        "connectivity": array(string("A SIM, eSIM or wifi note")),
        "electricity": array(string("Plug type or voltage")),
        "health": array(string("A health note")),
        "etiquette": array(string("A customs or manners note")),
    ], required: ["emergency", "safety", "money", "connectivity", "electricity", "health", "etiquette"])

    static let themes: [String: Any] = object([
        "themes": array(string("Short day title, at most 4 words")),
    ], required: ["themes"])

    static let tips: [String: Any] = object([
        "tips": array(string("One short tip")),
    ], required: ["tips"])
}
