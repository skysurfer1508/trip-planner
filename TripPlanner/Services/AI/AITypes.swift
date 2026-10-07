import Foundation

struct AIContext {
    var destination = ""
    var dates = ""
}

struct DayThemeInput {
    let day: Int
    let stops: [String]
}

struct DayEditItem {
    /// Short id used in the prompt ("s1" for a stop, "p3" for a place) so small models can't garble it.
    let alias: String
    let name: String
    let detail: String
}

struct DayEditRequest {
    var instruction: String
    var dayNumber: Int
    var destination: String
    var travellers: String
    var startTime: String?
    var stops: [DayEditItem]
    var candidates: [DayEditItem]
}

struct DayEditCommand {
    var action: String
    var stop: String = ""
    var candidate: String = ""
    var after: String = ""
    var time: String = ""
}

struct DayEditResponse {
    var summary: String
    var commands: [DayEditCommand]
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
    /// A short title for each planned day, in the same order as `days`.
    func dayThemes(_ days: [DayThemeInput], destination: String) async throws -> [String]
    /// Turns a free-text change request for one day into a few edits that only use the listed ids.
    func editDay(_ request: DayEditRequest) async throws -> DayEditResponse
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

    static func themes(_ days: [DayThemeInput], destination: String) -> String {
        var lines = ["Give each day of a trip to \(destination) a short, catchy title of at most 4 words that fits its stops. "
                     + "Return exactly \(days.count) titles in order, no numbering."]
        for day in days {
            lines.append("Day \(day.day): \(day.stops.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    static func editDay(_ request: DayEditRequest) -> String {
        var lines = [
            "You adjust ONE day of a travel plan for a trip to \(request.destination). Travellers: \(request.travellers).",
            "Day \(request.dayNumber)" + (request.startTime.map { " starts at \($0)." } ?? "."),
            "Current stops in order:",
        ]
        lines += request.stops.map { "- \($0.alias): \($0.name) (\($0.detail))" }
        lines.append("Places you may use:")
        lines += request.candidates.map { "- \($0.alias): \($0.name) (\($0.detail))" }
        lines.append("The traveller says: \"\(request.instruction)\"")
        lines.append("Answer with the smallest set of edits that does what they ask, using only the ids listed above. "
                     + "Actions: remove (stop = an s-id), replace (stop = an s-id, candidate = a p-id), "
                     + "add (candidate = a p-id, after = an s-id or empty), set_start (time = HH:mm). "
                     + "Leave unused fields empty. If nothing fits, return no edits and say why. "
                     + "The summary is one short sentence for the traveller about what you changed.")
        return lines.joined(separator: "\n")
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
