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
struct GenPlaceWish {
    @Guide(description: "Proper name of the place as on a map, without descriptions")
    var name: String
    @Guide(description: "Local-language name if different, otherwise an empty string")
    var localName: String
    @Guide(description: "One of: sight, food, cafe, nightlife, other")
    var kind: String
    @Guide(description: "HH:mm if the text says when to go there, otherwise an empty string")
    var statedTime: String
    @Guide(description: "HH:mm for the best time to visit this place when no time is stated")
    var bestTime: String
    @Guide(description: "Day number only if the text states it, otherwise an empty string")
    var day: String
}

@available(iOS 26.0, *)
@Generable
struct GenPlaceWishes {
    var places: [GenPlaceWish]
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
struct GenEdit {
    @Guide(description: "One of: remove, replace, add, set_start")
    var action: String
    @Guide(description: "An s-id from the current stops, or an empty string")
    var stop: String
    @Guide(description: "A p-id from the places list, or an empty string")
    var candidate: String
    @Guide(description: "An s-id to insert after, or an empty string")
    var after: String
    @Guide(description: "HH:mm for set_start, or an empty string")
    var time: String
}

@available(iOS 26.0, *)
@Generable
struct GenPlanEdit {
    @Guide(description: "One of: remove, move, set_time, shift_day, swap_days, retime, add, replace")
    var action: String
    @Guide(description: "An s-id from the plan, or an empty string")
    var stop: String
    @Guide(description: "A p-id from the places list, or an empty string")
    var place: String
    @Guide(description: "An s-id, the word first, or an empty string")
    var after: String
    @Guide(description: "A day number, or an empty string")
    var day: String
    @Guide(description: "A second day number for swap_days, or an empty string")
    var otherDay: String
    @Guide(description: "HH:mm, or minutes such as +60 or -30, or an empty string")
    var time: String
}

@available(iOS 26.0, *)
@Generable
struct GenPlanChange {
    @Guide(description: "One or two short sentences about what changed, or why nothing could change")
    var summary: String
    var edits: [GenPlanEdit]
}

@available(iOS 26.0, *)
@Generable
struct GenDayEdit {
    @Guide(description: "One short sentence about what changed, or why nothing could change")
    var summary: String
    var edits: [GenEdit]
}

@available(iOS 26.0, *)
@Generable
struct GenTransitNotes {
    @Guide(description: "Short notes about tickets and passes, only from the text")
    var tickets: [String]
    @Guide(description: "Short notes about apps or websites, only from the text")
    var apps: [String]
    @Guide(description: "Short practical tips, only from the text")
    var tips: [String]
}

@available(iOS 26.0, *)
@Generable
struct GenPractical {
    @Guide(description: "Emergency numbers and who to call, only from the text")
    var emergency: [String]
    @Guide(description: "Safety notes, only from the text")
    var safety: [String]
    @Guide(description: "Money, cards and tipping notes, only from the text")
    var money: [String]
    @Guide(description: "SIM, eSIM and wifi notes, only from the text")
    var connectivity: [String]
    @Guide(description: "Plug type and voltage, only if stated")
    var electricity: [String]
    @Guide(description: "Health notes, only from the text")
    var health: [String]
    @Guide(description: "Customs and manners, only from the text")
    var etiquette: [String]
}

@available(iOS 26.0, *)
@Generable
struct GenThemes {
    @Guide(description: "One short day title of at most 4 words per day, in order")
    var themes: [String]
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

    func extractPlaces(text: String, destination: String) async throws -> [PlaceWish] {
        var all: [PlaceWish] = []
        for chunk in TextChunker.chunks(text, limit: 500).prefix(24) {
            let result = try await respond(AIPrompts.places(text: chunk, destination: destination), as: GenPlaceWishes.self)
            let rows: [[String: Any]] = result.places.map { place in
                ["name": place.name, "localName": place.localName, "kind": place.kind,
                 "statedTime": place.statedTime, "bestTime": place.bestTime, "day": place.day]
            }
            all.append(contentsOf: PlaceWishJSON.parse(["places": rows]))
        }
        return all
    }

    func dayThemes(_ days: [DayThemeInput], destination: String) async throws -> [String] {
        let result = try await respond(AIPrompts.themes(days, destination: destination), as: GenThemes.self)
        return result.themes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func editPlan(_ request: PlanChatRequest) async throws -> PlanChatResponse {
        let result = try await respond(AIPrompts.editPlan(request), as: GenPlanChange.self)
        let rows: [[String: Any]] = result.edits.map { edit in
            ["action": edit.action, "stop": edit.stop, "place": edit.place, "after": edit.after,
             "day": edit.day, "otherDay": edit.otherDay, "time": edit.time]
        }
        return PlanChatJSON.parse(["summary": result.summary, "edits": rows])
    }

    func editDay(_ request: DayEditRequest) async throws -> DayEditResponse {
        let result = try await respond(AIPrompts.editDay(request), as: GenDayEdit.self)
        return DayEditResponse(summary: result.summary,
                               commands: result.edits.map {
                                   DayEditCommand(action: $0.action, stop: $0.stop, candidate: $0.candidate,
                                                  after: $0.after, time: $0.time)
                               })
    }

    func summarizeTransit(text: String, city: String) async throws -> TransitNotes {
        let result = try await respond(AIPrompts.transit(text: String(text.prefix(3_000)), city: city),
                                       as: GenTransitNotes.self)
        return TransitNotes(tickets: result.tickets.filter { !$0.isEmpty },
                            apps: result.apps.filter { !$0.isEmpty },
                            tips: result.tips.filter { !$0.isEmpty })
    }

    func summarizePractical(text: String, country: String) async throws -> PracticalNotes {
        let result = try await respond(AIPrompts.practical(text: String(text.prefix(3_000)), country: country),
                                       as: GenPractical.self)
        func clean(_ list: [String]) -> [String] { list.filter { !$0.isEmpty } }
        return PracticalNotes(emergency: clean(result.emergency), safety: clean(result.safety),
                              money: clean(result.money), connectivity: clean(result.connectivity),
                              electricity: clean(result.electricity), health: clean(result.health),
                              etiquette: clean(result.etiquette))
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
