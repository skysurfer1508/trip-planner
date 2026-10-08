import Foundation
import MapKit

/// A place the traveller insists on, with the time and day they would like to be there (both optional).
struct MustSee: Identifiable {
    let id = UUID()
    var item: MKMapItem
    /// Minutes after midnight.
    var preferredMinute: Int?
    /// 1 = first day of the plan.
    var preferredDay: Int?
    /// The time was chosen for the traveller (best time to visit), not asked for.
    var timeIsSuggested = false
    /// What the place is, when the map doesn't say (a place found without a category).
    var kindHint: DiscoverKind?

    var name: String { item.name ?? "Place" }

    /// "Around 18:30 · Day 2", or nil when the traveller has no preference.
    var whenText: String? { Self.whenText(minute: preferredMinute, day: preferredDay, suggested: timeIsSuggested) }

    static func whenText(minute: Int?, day: Int?, suggested: Bool = false) -> String? {
        var parts: [String] = []
        if let minute { parts.append("\(suggested ? "Best around" : "Around") \(TripLogistics.timeText(minute))") }
        if let day { parts.append("Day \(day)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The kind of place the planner should treat it as: a restaurant stays a meal, not a sight.
    var kind: DiscoverKind {
        if item.pointOfInterestCategory == nil, let kindHint { return kindHint }
        return Self.kind(of: item)
    }

    static func kind(of item: MKMapItem) -> DiscoverKind {
        switch StopCategory(poi: item.pointOfInterestCategory) {
        case .food: .food
        case .cafe: .cafe
        case .nightlife: .nightlife
        default: .sights
        }
    }

    func candidate() -> PlanCandidate {
        let coordinate = item.placemark.coordinate
        var candidate = PlanCandidate(id: "must-\(name)-\(coordinate.latitude)",
                                      name: name,
                                      coordinate: coordinate,
                                      kind: kind,
                                      score: 1,
                                      address: item.readableAddress ?? "",
                                      isMustSee: true)
        candidate.preferredMinute = preferredMinute
        candidate.preferredDay = preferredDay
        candidate.timeIsSuggested = timeIsSuggested
        return candidate
    }
}

extension PlanCandidate {
    /// A place the traveller searched for and added to a day by hand.
    init(picked item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        self.init(id: "picked-\(item.name ?? "")-\(coordinate.latitude)",
                  name: item.name ?? "Place",
                  coordinate: coordinate,
                  kind: MustSee.kind(of: item),
                  score: 0.5,
                  address: item.readableAddress ?? "")
    }
}

/// Understands what someone types into the "what do you want to see" box:
/// "Belém Tower at sunset on day 2" -> place "Belém Tower", around 19:00, day 2.
/// Plain pattern matching, so it works without any AI engine.
enum MustSeeParser {
    struct Parsed: Equatable {
        var query: String
        var minute: Int?
        var day: Int?
    }

    private static let periods: [(words: String, minute: Int)] = [
        ("sunrise|sonnenaufgang", 7 * 60),
        ("sunset|sonnenuntergang", 19 * 60),
        ("midday|noon|mittags?", 12 * 60),
        ("morning|morgens|vormittags?", 9 * 60 + 30),
        ("afternoon|nachmittags?", 14 * 60 + 30),
        ("evening|abends?", 18 * 60 + 30),
        ("tonight|at night|nachts?", 21 * 60),
    ]

    static func parse(_ text: String) -> Parsed {
        var rest = " \(text) "
        var minute: Int?
        var day: Int?

        // Day: "day 2", "on day 3", "Tag 2".
        if let found = find(#"\b(?:on\s+)?(?:day|tag)\s*(\d{1,2})\b"#, in: rest) {
            day = Int(found.groups[0])
            rest.removeSubrange(found.range)
        }

        // Clock times: "18:30", "6:30 pm", "6pm", "18 Uhr", "at 19".
        let connector = #"(?:\b(?:at|around|about|by|um|gegen|ab)\s+)?"#
        if let found = find(connector + #"\b(\d{1,2})[:.](\d{2})\s*(am|pm|uhr)?\b"#, in: rest),
           let value = clock(hour: found.groups[0], minute: found.groups[1], suffix: found.groups[2]) {
            minute = value
            rest.removeSubrange(found.range)
        } else if let found = find(connector + #"\b(\d{1,2})\s*(am|pm|uhr|h)\b"#, in: rest),
                  let value = clock(hour: found.groups[0], minute: "0", suffix: found.groups[1]) {
            minute = value
            rest.removeSubrange(found.range)
        } else if let found = find(#"\b(?:at|um)\s+(\d{1,2})\b"#, in: rest),
                  let hour = Int(found.groups[0]), (8...23).contains(hour) {
            minute = hour * 60
            rest.removeSubrange(found.range)
        }

        // Parts of the day: "in the evening", "at sunset".
        if minute == nil {
            for period in periods {
                if let found = find(#"\b(?:in the |during the |at |am |zum )?(?:"# + period.words + #")\b"#, in: rest) {
                    minute = period.minute
                    rest.removeSubrange(found.range)
                    break
                }
            }
        }

        return Parsed(query: clean(rest), minute: minute, day: day)
    }

    // MARK: Best time without an AI

    /// A sensible time for places whose name says when they are at their best. Nil when it doesn't matter.
    static func suggestedMinute(forName name: String) -> Int? {
        let folded = PlaceFinder.fold(name)
        let words = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let rules: [(words: Set<String>, minute: Int)] = [
            (["observatory", "skybar", "rooftop", "skyline", "nightlife", "club", "pub", "lounge", "bar"], 21 * 60),
            (["sunset", "viewpoint", "mirador", "belvedere", "lookout"], 19 * 60),
            (["market", "bazaar", "bakery", "farmers"], 10 * 60),
            (["sunrise"], 7 * 60),
        ]
        if folded.contains("night market") { return 20 * 60 }
        return rules.first { !$0.words.isDisjoint(with: words) }?.minute
    }

    // MARK: Several places in one text

    /// A list or paragraph instead of one place: several lines, numbered items, or a long text.
    static func looksLikeList(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count > 1 { return true }
        let markers = (try? NSRegularExpression(pattern: #"(?:^|\s)\d{1,2}[.)]\s+\S"#))
            .map { $0.numberOfMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) } ?? 0
        return markers >= 2 || trimmed.count > 90
    }

    /// Splits such a text into places without any AI: at numbers, lines, semicolons and "or", dropping
    /// the explanations ("... for a beautiful view", "maybe also at night").
    static func split(_ text: String) -> [Parsed] {
        var working = text.replacingOccurrences(of: #"(?:^|\s)\d{1,2}[.)]\s+(?=\S)"#, with: "\n",
                                                options: .regularExpression)
        working = working.replacingOccurrences(of: #"[;•·]|\s[-–—]\s|\s(?:or|and then|oder|und dann)\s"#,
                                               with: "\n", options: [.regularExpression, .caseInsensitive])
        var seen = Set<String>()
        var result: [Parsed] = []
        for line in working.split(whereSeparator: \.isNewline) {
            var parsed = parse(String(line))
            parsed.query = withoutExplanation(parsed.query)
            let key = parsed.query.lowercased()
            guard parsed.query.count >= 3, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(parsed)
        }
        return result
    }

    /// "Place of culture observatory for a beautiful view" -> "Place of culture observatory".
    static func withoutExplanation(_ text: String) -> String {
        var result = text
        let always = #"\s+(?:maybe|also|because|which|where|especially|but)\b.*$"#
        result = result.replacingOccurrences(of: always, with: "", options: [.regularExpression, .caseInsensitive])
        // "for"/"with" can be part of a name ("Museum for Modern Art"): only cut after a longer name.
        if let range = result.range(of: #"\s+(?:for|with|to see|so that)\b"#, options: [.regularExpression, .caseInsensitive]),
           result[..<range.lowerBound].split(separator: " ").count >= 2 {
            result = String(result[..<range.lowerBound])
        }
        return clean(result)
    }

    // MARK: Helpers

    private static func clock(hour: String, minute: String, suffix: String) -> Int? {
        guard var h = Int(hour), let m = Int(minute), m < 60 else { return nil }
        switch suffix.lowercased() {
        case "pm": if h < 12 { h += 12 }
        case "am": if h == 12 { h = 0 }
        default: break
        }
        guard (0..<24).contains(h) else { return nil }
        return h * 60 + m
    }

    private static func find(_ pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        var groups: [String] = []
        for index in 1..<max(match.numberOfRanges, 1) {
            if let groupRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append("")
            }
        }
        return (range, groups)
    }

    /// Removes "I want to see", dangling "at"/"on" and extra spaces.
    private static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let leading = [
            #"^\s*(?:i|we)\s+(?:really\s+)?(?:want|would like|'d like|wanna)\s+to\s+(?:see|visit|go to|check out)\s+"#,
            #"^\s*(?:i|we)'d\s+like\s+to\s+(?:see|visit|go to)\s+"#,
            #"^\s*(?:visit|see|go to|check out|besuchen|sehen)\s+"#,
            #"^\s*(?:at|on|in|around|by|the)\s+"#,
        ]
        let trailing = [#"\s+(?:at|on|in|in the|around|by|um|am|im|gegen|and|for)\s*$"#, #"[\s,;.-]+$"#]
        var changed = true
        while changed {
            changed = false
            for pattern in leading + trailing {
                let next = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                if next != result {
                    result = next
                    changed = true
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
