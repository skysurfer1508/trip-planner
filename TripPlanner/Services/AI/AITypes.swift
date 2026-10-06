import Foundation

struct AIContext {
    var destination = ""
    var dates = ""
}

struct DraftRequest {
    var destination: String
    var days: Int
    var interests: [String]
    var pace: String
    var budget: String
}

struct PickCandidate {
    let id: String
    let name: String
    let detail: String
}

struct PicksRequest {
    var now: String
    var weather: String?
    var remaining: [String]
    var candidates: [PickCandidate]
}

struct AIPick {
    let id: String
    let reason: String
}

enum AIError: LocalizedError {
    case rateLimited
    case api(String)
    case badOutput
    case unavailable

    var errorDescription: String? {
        switch self {
        case .rateLimited: "The free AI limit was reached. Try again in a minute."
        case .api(let message): "AI request failed: \(message)"
        case .badOutput: "The AI returned something unexpected."
        case .unavailable: "No AI is available. Turn on Apple Intelligence or add a free Gemini key in Settings."
        }
    }
}

/// One AI backend (on-device or Gemini). Features only talk to this protocol.
protocol AIEngine {
    var label: String { get }
    func extractItinerary(text: String, context: AIContext) async throws -> ParsedItinerary
    func draftItinerary(_ request: DraftRequest) async throws -> ParsedItinerary
    func rankPicks(_ request: PicksRequest) async throws -> [AIPick]
    func placeTips(name: String, city: String) async throws -> [String]
}

enum AIPrompts {
    static func extract(text: String, context: AIContext) -> String {
        """
        Extract the day-by-day travel program from the document below. Include only things a traveller \
        would go to or do at a specific place (sights, meals, hotels, stations). Leave out prices, booking \
        numbers, general notes and advertising. Keep names in the document's language. \
        Trip destination: \(context.destination.isEmpty ? "unknown" : context.destination). Trip dates: \(context.dates).

        DOCUMENT:
        \(text)
        """
    }

    static func draft(_ request: DraftRequest) -> String {
        """
        Plan a \(request.days)-day trip to \(request.destination). Interests: \
        \(request.interests.isEmpty ? "a bit of everything" : request.interests.joined(separator: ", ")). \
        Pace: \(request.pace). Budget: \(request.budget). \
        For each day give 3 to 6 stops in a sensible geographic order, including a lunch or dinner place. \
        Use real, well-known places and write their exact names with the city so they can be found on a map. \
        Give a start time (HH:mm, 24 hour) for each stop and a day label like "Day 1".
        """
    }

    static func picks(_ request: PicksRequest) -> String {
        var lines = ["A traveller asks what to do next. Current time: \(request.now)."]
        if let weather = request.weather { lines.append("Weather today: \(weather).") }
        if !request.remaining.isEmpty {
            lines.append("Still planned today: \(request.remaining.joined(separator: "; ")).")
        }
        lines.append("Choose up to 3 of these candidates that fit best right now and give a one-sentence reason each. "
                     + "Use only the ids listed.")
        for candidate in request.candidates {
            lines.append("- id \(candidate.id): \(candidate.name) (\(candidate.detail))")
        }
        return lines.joined(separator: "\n")
    }

    static func tips(name: String, city: String) -> String {
        "Give 3 short practical tips (each under 20 words) for visiting \(name)\(city.isEmpty ? "" : " in \(city)"): "
            + "why it's worth it, the best time to go, and one insider tip. Only say things you are confident about."
    }
}
