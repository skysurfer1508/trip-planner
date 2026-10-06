#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct GenStop {
    @Guide(description: "Name of the place or venue with the city, suitable for a map search")
    var title: String
    @Guide(description: "Start time as HH:mm in 24 hour format, or an empty string")
    var time: String
    @Guide(description: "Short useful note, or an empty string")
    var notes: String
    @Guide(description: "One of: sight, food, cafe, hotel, transport, other")
    var category: String
}

@available(iOS 26.0, *)
@Generable
struct GenDay {
    @Guide(description: "Heading of the day, for example Day 2")
    var label: String
    @Guide(description: "Date as yyyy-MM-dd, or an empty string if unknown")
    var date: String
    var stops: [GenStop]
}

@available(iOS 26.0, *)
@Generable
struct GenItinerary {
    var days: [GenDay]
}

@available(iOS 26.0, *)
@Generable
struct GenPick {
    @Guide(description: "The candidate id exactly as given")
    var id: String
    @Guide(description: "One sentence why it fits right now")
    var reason: String
}

@available(iOS 26.0, *)
@Generable
struct GenPicks {
    var picks: [GenPick]
}

@available(iOS 26.0, *)
@Generable
struct GenTips {
    @Guide(description: "Three short practical tips")
    var tips: [String]
}

/// Apple Intelligence running on the device: free, private, works offline. Needs iOS 26 and a
/// device with Apple Intelligence turned on. The context window is small, so documents are
/// processed in chunks.
@available(iOS 26.0, *)
struct OnDeviceAI: AIEngine {
    var label: String { "Apple Intelligence" }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func extractItinerary(text: String, context: AIContext) async throws -> ParsedItinerary {
        var days: [ParsedDay] = []
        for chunk in TextChunker.chunks(text).prefix(12) {
            let result = try await respond(AIPrompts.extract(text: chunk, context: context), as: GenItinerary.self)
            for day in ItineraryJSON.parse(dictionary(result)).days {
                // A day that continues across two chunks arrives twice with the same heading.
                if let last = days.indices.last, let label = day.label, days[last].label == label {
                    days[last].stops.append(contentsOf: day.stops)
                } else {
                    days.append(day)
                }
            }
        }
        return ParsedItinerary(days: days)
    }

    func draftItinerary(_ request: DraftRequest) async throws -> ParsedItinerary {
        let result = try await respond(AIPrompts.draft(request), as: GenItinerary.self)
        return ItineraryJSON.parse(dictionary(result))
    }

    func rankPicks(_ request: PicksRequest) async throws -> [AIPick] {
        var limited = request
        limited.candidates = Array(request.candidates.prefix(12))
        let result = try await respond(AIPrompts.picks(limited), as: GenPicks.self)
        return result.picks.map { AIPick(id: $0.id, reason: $0.reason) }
    }

    func placeTips(name: String, city: String) async throws -> [String] {
        let result = try await respond(AIPrompts.tips(name: name, city: city), as: GenTips.self)
        return result.tips.filter { !$0.isEmpty }
    }

    // MARK: Helpers

    private func respond<T: Generable>(_ prompt: String, as type: T.Type) async throws -> T {
        let session = LanguageModelSession(instructions: "You help plan trips. Answer only from the given text and facts.")
        let response = try await session.respond(to: prompt, generating: type)
        return response.content
    }

    private func dictionary(_ itinerary: GenItinerary) -> [String: Any] {
        let days: [[String: Any]] = itinerary.days.map { day in
            let stops: [[String: Any]] = day.stops.map { stop in
                ["title": stop.title, "time": stop.time, "notes": stop.notes, "category": stop.category]
            }
            return ["label": day.label, "date": day.date, "stops": stops]
        }
        return ["days": days]
    }
}
#endif
