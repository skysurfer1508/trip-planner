import Foundation
import NaturalLanguage

/// On-device itinerary parsing: finds day headers, times and short place-like lines.
/// It handles the common layouts ("Day 2", "Monday, June 5", "10:00 Louvre", bullet lists,
/// table rows). Messy documents are better served by an AI engine (see `AIRouter`).
enum ItineraryParser {
    static func parse(_ text: String, tripRange: ClosedRange<Date>?) -> ParsedItinerary {
        var days: [ParsedDay] = []
        var current = ParsedDay(label: nil, date: nil)

        func flush() {
            if !current.stops.isEmpty || current.label != nil || current.date != nil {
                days.append(current)
            }
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: "  ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            if let header = dayHeader(line) {
                flush()
                current = ParsedDay(label: header.label, date: header.date)
            } else if let stop = candidate(line) {
                current.stops.append(stop)
            }
        }
        flush()

        // Headers without stops are noise (e.g. a title line that looked like a date).
        days = days.filter { !$0.stops.isEmpty }

        if let tripRange {
            for index in days.indices {
                if let date = days[index].date {
                    days[index].date = align(date, to: tripRange)
                }
            }
        }
        return ParsedItinerary(days: days)
    }

    // MARK: Day headers

    private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
    ]

    private static func dayHeader(_ line: String) -> (label: String, date: Date?)? {
        let lower = line.lowercased()

        if matches(#"^(day|tag|jour|día|dia|giorno)\s*\d+"#, in: lower) {
            return (line, detectDate(in: line)?.date)
        }
        if weekdays.contains(lower.trimmingCharacters(in: CharacterSet(charactersIn: " :.,-–"))) {
            return (line, nil)
        }
        // A short line that is (almost) entirely a date: "Monday, June 5", "05.06.2026".
        if line.count <= 40, let found = detectDate(in: line),
           Double(found.length) >= Double(line.count) * 0.6,
           leadingTime(line) == nil {
            return (line, found.date)
        }
        return nil
    }

    private static func detectDate(in line: String) -> (date: Date, length: Int)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = dateDetector?.firstMatch(in: line, options: [], range: range),
              let date = match.date else { return nil }
        return (date, match.range.length)
    }

    /// Dates without a year come back in the current year; move them into the trip's year.
    private static func align(_ date: Date, to range: ClosedRange<Date>) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.month, .day], from: date)
        let startYear = calendar.component(.year, from: range.lowerBound)
        let slack: TimeInterval = 30 * 86_400
        for year in [startYear, startYear + 1] {
            var components = parts
            components.year = year
            if let candidate = calendar.date(from: components),
               candidate >= range.lowerBound.addingTimeInterval(-slack),
               candidate <= range.upperBound.addingTimeInterval(slack) {
                return candidate
            }
        }
        return date
    }

    // MARK: Stops

    private static let bullets = CharacterSet(charactersIn: "-*•–—·▪●▶➤✓✔☐□■◦> ")

    private static let skipWords = [
        "http", "www.", "@", "confirmation", "booking ref", "reservation", "total", "page ",
        "passport", "tel:", "phone", "invoice", "price", "terms",
    ]

    private static let genericWords: Set<String> = [
        "morning", "afternoon", "evening", "night", "lunch", "dinner", "breakfast", "free time",
        "notes", "program", "programme", "itinerary", "schedule", "overview",
        "morgens", "mittags", "abends", "frühstück", "mittagessen", "abendessen", "freizeit",
    ]

    private static func candidate(_ raw: String) -> ParsedStop? {
        let hadBullet = raw.unicodeScalars.first.map { bullets.contains($0) && $0 != " " } ?? false
        let line = raw.trimmingCharacters(in: bullets)
        guard line.contains(where: \.isLetter), line.count >= 2 else { return nil }
        let lower = line.lowercased()
        guard !skipWords.contains(where: { lower.contains($0) }) else { return nil }

        if let time = leadingTime(line) {
            let title = clean(time.rest)
            guard title.contains(where: \.isLetter) else { return nil }
            var stop = ParsedStop(title: title, hour: time.hour, minute: time.minute)
            stop.category = guessCategory(title)
            stop.confidence = genericWords.contains(title.lowercased()) ? 0.3 : 1
            return stop
        }

        // No time: only keep short, name-like lines.
        let words = line.split(separator: " ")
        guard line.count <= 80, words.count <= 10, !line.hasSuffix("."),
              !genericWords.contains(lower),
              digitRatio(line) < 0.3 else { return nil }

        var stop = ParsedStop(title: clean(line))
        stop.category = guessCategory(line)
        stop.confidence = hasPlaceTag(line) ? 0.8 : (hadBullet ? 0.6 : 0.3)
        return stop
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|•·,\t"))
        while result.hasSuffix(",") || result.hasSuffix(";") || result.hasSuffix(":") {
            result.removeLast()
        }
        return result
    }

    private static func digitRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        return Double(text.filter(\.isNumber).count) / Double(text.count)
    }

    private static func hasPlaceTag(_ line: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = line
        var found = false
        tagger.enumerateTags(in: line.startIndex..<line.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .placeName || tag == .organizationName {
                found = true
                return false
            }
            return true
        }
        return found
    }

    static func guessCategory(_ text: String) -> StopCategory {
        let lower = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        if has(["café", "cafe", "coffee", "bakery", "pastel", "kaffee"]) { return .cafe }
        if has(["lunch", "dinner", "breakfast", "restaurant", "bistro", "trattoria", "tapas", "brunch",
                "mittagessen", "abendessen", "frühstück", "pizzeria", "bar "]) { return .food }
        if has(["hotel", "check-in", "check in", "hostel", "airbnb", "apartment", "unterkunft"]) { return .hotel }
        if has(["airport", "flight", "train", "station", "bus", "ferry", "transfer", "bahnhof", "flughafen"]) { return .transport }
        if has(["museum", "castle", "cathedral", "church", "tower", "palace", "park", "beach", "market",
                "square", "temple", "gallery", "tour", "viewpoint", "mirador", "miradouro", "schloss", "dom"]) { return .sight }
        return .other
    }

    // MARK: Times

    /// Reads "09:30", "9.30", "9h30", "9am", "10 Uhr" at the start of a line (and skips a "– 11:00"
    /// end time).
    static func leadingTime(_ line: String) -> (hour: Int, minute: Int, rest: String)? {
        let patterns = [
            #"^(\d{1,2})[:.h](\d{2})(?![\d/]|\.\d)\s*(am|pm|uhr)?"#,
            #"^(\d{1,2})\s*(am|pm|uhr)\b"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }

            func group(_ i: Int) -> String? {
                guard i < match.numberOfRanges, let range = Range(match.range(at: i), in: line) else { return nil }
                return String(line[range])
            }
            guard var hour = group(1).flatMap({ Int($0) }) else { continue }
            let minute = index == 0 ? (group(2).flatMap { Int($0) } ?? 0) : 0
            let suffix = (index == 0 ? group(3) : group(2))?.lowercased()
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            guard (0..<24).contains(hour), (0..<60).contains(minute) else { continue }

            var rest = String(line[Range(match.range, in: line)!.upperBound...])
            if let range = rest.range(of: #"^\s*[-–—]\s*\d{1,2}[:.]\d{2}\s*(am|pm|uhr)?"#,
                                      options: [.regularExpression, .caseInsensitive]) {
                rest.removeSubrange(range)
            }
            return (hour, minute, rest)
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
