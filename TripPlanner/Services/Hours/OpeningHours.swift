import Foundation

/// A parsed OpenStreetMap `opening_hours` value ("Mo-Fr 09:00-17:00; Sa 10:00-14:00; PH off").
/// Supports weekdays, public holidays, months ("Oct-Apr: ..."), several time ranges, overnight hours,
/// "off" and "24/7". Anything fancier (weeks, sunrise, dates, open ends) is not understood, so
/// `parse` returns nil and the app shows the raw text without making claims.
struct OpeningHours {
    struct Interval: Equatable {
        var start: Int
        /// Minutes after midnight; above 1440 means the next morning.
        var end: Int
    }

    struct Rule {
        var months: Set<Int>?
        /// ISO weekdays, 1 = Monday ... 7 = Sunday. Empty means every day.
        var weekdays: Set<Int>
        var appliesOnHolidays: Bool
        var isOff: Bool
        var intervals: [Interval]

        var holidaysOnly: Bool { weekdays.isEmpty && appliesOnHolidays }
    }

    enum DayHours: Equatable {
        case closed
        case open([Interval])
        /// A season the rules don't cover.
        case unknown
    }

    enum Verdict: Equatable {
        case open
        case opensLater(Int)
        case closesEarly(Int)
        case closed(String)
        case unknown
    }

    let rules: [Rule]

    // MARK: Parsing

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                     "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["mo": 1, "tu": 2, "we": 3, "th": 4, "fr": 5, "sa": 6, "su": 7]

    private final class Box {
        let value: OpeningHours?
        init(_ value: OpeningHours?) { self.value = value }
    }

    private static let parsed = NSCache<NSString, Box>()

    /// Parsed once per text: rows ask for the same hours again and again while a list scrolls.
    static func parse(_ text: String) -> OpeningHours? {
        let key = text as NSString
        if let known = parsed.object(forKey: key) { return known.value }
        let value = parseUncached(text)
        parsed.setObject(Box(value), forKey: key)
        return value
    }

    private static func parseUncached(_ text: String) -> OpeningHours? {
        let cleaned = text.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()

        if lower == "24/7" {
            return OpeningHours(rules: [Rule(months: nil, weekdays: [], appliesOnHolidays: true, isOff: false,
                                             intervals: [Interval(start: 0, end: 1440)])])
        }
        if isUnsupported(lower) { return nil }

        var rules: [Rule] = []
        for part in cleaned.split(separator: ";") {
            for piece in splitRules(String(part)) {
                guard let rule = parseRule(piece) else { return nil }
                rules.append(rule)
            }
        }
        return rules.isEmpty ? nil : OpeningHours(rules: rules)
    }

    private static func isUnsupported(_ lower: String) -> Bool {
        let patterns = [
            "week", "sunrise", "sunset", "dusk", "dawn", "easter", "\\bsh\\b", "\\+", "\\[", "\\|\\|",
            "\\d{4}", "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\s*\\d", "\\bopen\\b", "unknown",
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// "Mo-Fr 09:00-12:00, Sa 10:00-14:00" is two rules; "Mo,We 10:00-12:00" is one.
    private static func splitRules(_ text: String) -> [String] {
        let pattern = "(?<=\\d),\\s+(?=(Mo|Tu|We|Th|Fr|Sa|Su|PH|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var pieces: [String] = []
        var last = text.startIndex
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            pieces.append(String(text[last..<r.lowerBound]))
            last = r.upperBound
        }
        pieces.append(String(text[last...]))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseRule(_ text: String) -> Rule? {
        var months: Set<Int>?
        var weekdays = Set<Int>()
        var holiday = false
        var intervals: [Interval] = []
        var off = false

        for rawToken in text.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let lower = token.lowercased()
            if lower == "off" || lower == "closed" {
                off = true
            } else if let found = parseMonths(token) {
                months = (months ?? []).union(found)
            } else if let found = parseWeekdays(token) {
                weekdays.formUnion(found.days)
                holiday = holiday || found.holiday
            } else if let found = parseTimes(token) {
                intervals += found
            } else {
                return nil
            }
        }
        if !off && intervals.isEmpty { return nil }
        return Rule(months: months, weekdays: weekdays, appliesOnHolidays: holiday, isOff: off, intervals: intervals)
    }

    private static func range(_ a: Int, _ b: Int, upTo limit: Int) -> [Int] {
        a <= b ? Array(a...b) : Array(a...limit) + Array(1...b)
    }

    private static func parseMonths(_ token: String) -> Set<Int>? {
        var result = Set<Int>()
        for part in token.lowercased().split(separator: ",") {
            let ends = part.split(separator: "-").map(String.init)
            guard (1...2).contains(ends.count), let first = monthNames[ends[0]] else { return nil }
            if ends.count == 2 {
                guard let second = monthNames[ends[1]] else { return nil }
                result.formUnion(range(first, second, upTo: 12))
            } else {
                result.insert(first)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func parseWeekdays(_ token: String) -> (days: Set<Int>, holiday: Bool)? {
        var days = Set<Int>()
        var holiday = false
        for part in token.lowercased().split(separator: ",") {
            if part == "ph" {
                holiday = true
                continue
            }
            let ends = part.split(separator: "-").map(String.init)
            guard (1...2).contains(ends.count), let first = dayNames[ends[0]] else { return nil }
            if ends.count == 2 {
                guard let second = dayNames[ends[1]] else { return nil }
                days.formUnion(range(first, second, upTo: 7))
            } else {
                days.insert(first)
            }
        }
        return (days.isEmpty && !holiday) ? nil : (days, holiday)
    }

    private static func parseTimes(_ token: String) -> [Interval]? {
        var result: [Interval] = []
        let pattern = "^(\\d{1,2}):(\\d{2})-(\\d{1,2}):(\\d{2})$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for part in token.split(separator: ",") {
            let text = String(part)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            func number(_ index: Int) -> Int {
                Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } ?? 0
            }
            let start = number(1) * 60 + number(2)
            var end = number(3) * 60 + number(4)
            guard number(1) <= 24, number(3) <= 24, number(2) < 60, number(4) < 60 else { return nil }
            if end <= start { end += 1440 }
            result.append(Interval(start: start, end: end))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: Evaluating

    private func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    private func matches(_ rule: Rule, month: Int, weekday: Int, holiday: Bool) -> Bool {
        if let months = rule.months, !months.contains(month) { return false }
        if rule.holidaysOnly { return holiday }
        if rule.weekdays.isEmpty { return true }
        if rule.weekdays.contains(weekday) { return true }
        return rule.appliesOnHolidays && holiday
    }

    /// What the rules say for one calendar day (without the hours that spill over from the day before).
    private func ownHours(on date: Date, holiday: Bool, calendar: Calendar) -> DayHours {
        let month = calendar.component(.month, from: date)
        let weekday = isoWeekday(date, calendar)
        var result: DayHours?
        for rule in rules where matches(rule, month: month, weekday: weekday, holiday: holiday) {
            result = rule.isOff ? .closed : .open(rule.intervals)
        }
        if let result { return result }
        // Rules that only cover other months say nothing about this month; a covered month where no
        // rule fits this weekday means closed.
        let monthCovered = rules.contains { $0.months?.contains(month) ?? true }
        return monthCovered ? .closed : .unknown
    }

    /// Opening hours of a day, including hours that run past midnight from the day before.
    func hours(on date: Date, isHoliday: (Date) -> Bool, calendar: Calendar = .current) -> DayHours {
        var own = ownHours(on: date, holiday: isHoliday(date), calendar: calendar)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: date),
           case .open(let previous) = ownHours(on: yesterday, holiday: isHoliday(yesterday), calendar: calendar) {
            let spill = previous.filter { $0.end > 1440 }.map { Interval(start: 0, end: $0.end - 1440) }
            if !spill.isEmpty {
                switch own {
                case .open(let intervals): own = .open(spill + intervals)
                case .closed: own = .open(spill)
                case .unknown: break
                }
            }
        }
        if case .open(let intervals) = own {
            return .open(intervals.sorted { $0.start < $1.start })
        }
        return own
    }

    /// Can you visit at `start` for `minutes`?
    func verdict(visitAt start: Date, minutes: Int, isHoliday: (Date) -> Bool, calendar: Calendar = .current) -> Verdict {
        func closedMessage() -> String {
            let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: start) - 1]
            return isHoliday(start) ? "Closed on public holidays" : "Closed on \(weekday)s"
        }

        switch hours(on: start, isHoliday: isHoliday, calendar: calendar) {
        case .unknown:
            return .unknown
        case .closed:
            return .closed(closedMessage())
        case .open(let intervals):
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            let begin = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let finish = begin + minutes
            if let current = intervals.first(where: { $0.start <= begin && begin < $0.end }) {
                var end = current.end
                // Open until midnight and again from midnight (e.g. 24/7): the visit may run on.
                if end == 1440, let tomorrow = calendar.date(byAdding: .day, value: 1, to: start),
                   case .open(let nextDay) = hours(on: tomorrow, isHoliday: isHoliday, calendar: calendar),
                   let first = nextDay.first, first.start == 0 {
                    end = 1440 + first.end
                }
                return finish <= end + 20 ? .open : .closesEarly(current.end)
            }
            if let next = intervals.first(where: { $0.start > begin }) {
                return .opensLater(next.start)
            }
            // Only hours that spilled over from yesterday: today itself is closed.
            if case .closed = ownHours(on: start, holiday: isHoliday(start), calendar: calendar) {
                return .closed(closedMessage())
            }
            return .closed("Closed after \(Self.clock(intervals.last?.end ?? 0))")
        }
    }

    // MARK: Text

    static func clock(_ minute: Int) -> String {
        // Past midnight reads as the next morning (26:00 is 02:00); midnight itself stays 24:00.
        let value = minute == 1440 ? 1440 : minute % 1440
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// "10:00–17:30", "Closed", "Hours vary".
    func text(on date: Date, isHoliday: (Date) -> Bool, calendar: Calendar = .current) -> String {
        switch hours(on: date, isHoliday: isHoliday, calendar: calendar) {
        case .closed: return "Closed"
        case .unknown: return "Not stated for this season"
        case .open(let intervals):
            return intervals.map { "\(Self.clock($0.start))–\(Self.clock($0.end > 1440 ? $0.end - 1440 : $0.end))" }
                .joined(separator: ", ")
        }
    }

    /// The seven days (Monday first) of the week around `date`, for the detail screen.
    func week(around date: Date, isHoliday: (Date) -> Bool, calendar: Calendar = .current) -> [(day: String, text: String)] {
        let weekdayIndex = isoWeekday(date, calendar) - 1
        guard let monday = calendar.date(byAdding: .day, value: -weekdayIndex, to: date) else { return [] }
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names.enumerated().compactMap { offset, name in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            return (name, text(on: day, isHoliday: isHoliday, calendar: calendar))
        }
    }

    /// A short warning for a plan row, or nil when everything is fine or unknown.
    static func warning(for verdict: Verdict) -> String? {
        switch verdict {
        case .open, .unknown: nil
        case .opensLater(let minute): "Opens at \(clock(minute)), after your planned time"
        case .closesEarly(let minute): "Closes at \(clock(minute)), before your visit ends"
        case .closed(let message): message
        }
    }
}
