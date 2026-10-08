import Foundation

/// What a receipt says: the total, its currency, the date, the shop. Reads the text that text recognition
/// found on a photo. Handles Polish, German and English receipts (and most others by their symbols).
struct ReceiptResult: Equatable {
    var amount: Double?
    var currency: String?
    var date: Date?
    var merchant: String?
    var category: ExpenseCategory?
}

enum ReceiptParser {
    // MARK: Words

    /// A line with one of these holds the total.
    private static let totalWords = [
        "total", "suma", "razem", "do zaplaty", "do zapłaty", "summe", "gesamt", "gesamtbetrag", "zu zahlen", "betrag",
        "amount due", "grand total", "totale", "importe", "total a pagar", "a payer", "à payer", "celkem", "osszesen",
    ]
    /// ...unless it also has one of these (subtotals, tax, change given back).
    private static let notTheTotal = [
        "subtotal", "zwischensumme", "netto", "mwst", "vat", "ptu", "tax", "steuer", "change", "rest", "reszta", "wydano",
        "gegeben", "zurück", "zuruck", "bar ", "cash", "received", "otrzymano", "tip", "trinkgeld", "napiwek",
    ]
    private static let notAMerchant = [
        "paragon", "fiskaln", "receipt", "rechnung", "beleg", "kasa", "nip", "tel", "www", "http", "kassenbon", "faktura",
        "dokument", "invoice", "ticket",
    ]

    private static let currencies: [(code: String, marks: [String])] = [
        ("PLN", ["pln", "zł", "zl"]), ("EUR", ["eur", "€"]), ("CHF", ["chf", "fr."]), ("USD", ["usd", "$"]),
        ("GBP", ["gbp", "£"]), ("CZK", ["czk", "kč", "kc"]), ("HUF", ["huf", " ft"]), ("SEK", ["sek"]),
        ("NOK", ["nok"]), ("DKK", ["dkk"]),
    ]

    // MARK: Parsing

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ReceiptResult {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result = ReceiptResult()
        let (amount, totalLine) = total(in: lines)
        result.amount = amount
        result.currency = currency(in: totalLine ?? "") ?? currency(in: text)
        result.date = date(in: text, now: now, calendar: calendar)
        result.merchant = merchant(in: lines)
        result.category = category(for: text)
        return result
    }

    /// Money amounts in a line: "45,80", "1 234,50", "1.234,50", "1,234.50", "45.80".
    static func amounts(in line: String) -> [Double] {
        let pattern = #"(?<![\d.,])(\d{1,3}(?:[ .,\x{00A0}]\d{3})+[.,]\d{2}|\d+[.,]\d{2})(?!\d|[.,]\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).flatMap { number(String(line[$0])) }
        }
    }

    /// "1.234,50" and "1,234.50" are both 1234.5: the last separator is the decimal one.
    static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        guard let separator = cleaned.lastIndex(where: { $0 == "." || $0 == "," }) else { return Double(cleaned) }
        let whole = cleaned[..<separator].filter(\.isNumber)
        let fraction = cleaned[cleaned.index(after: separator)...].filter(\.isNumber)
        return Double("\(whole).\(fraction)")
    }

    private static func total(in lines: [String]) -> (amount: Double?, line: String?) {
        var candidates: [(Double, String)] = []
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard totalWords.contains(where: { lower.contains($0) }),
                  !notTheTotal.contains(where: { lower.contains($0) }) else { continue }
            var found = amounts(in: line)
            var source = line
            if found.isEmpty, lines.indices.contains(index + 1) {       // the amount is on the next line
                found = amounts(in: lines[index + 1])
                source = lines[index + 1]
            }
            if let biggest = found.max() { candidates.append((biggest, source)) }
        }
        if let best = candidates.max(by: { $0.0 < $1.0 }) { return (best.0, best.1) }
        // No "total" line: the biggest amount on the receipt.
        var all: [(Double, String)] = []
        for line in lines {
            for value in amounts(in: line) { all.append((value, line)) }
        }
        if let best = all.max(by: { $0.0 < $1.0 }) { return (best.0, best.1) }
        return (nil, nil)
    }

    private static func currency(in text: String) -> String? {
        let lower = " " + text.lowercased() + " "
        for entry in currencies where entry.marks.contains(where: { lower.contains($0) }) {
            return entry.code
        }
        return nil
    }

    private static func date(in text: String, now: Date, calendar: Calendar) -> Date? {
        let patterns: [(String, [Int])] = [
            (#"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)"#, [0, 1, 2]),      // 2026-10-14
            (#"(?<!\d)(\d{1,2})[./-](\d{1,2})[./-](\d{4})(?!\d)"#, [2, 1, 0]),      // 14.10.2026
            (#"(?<!\d)(\d{1,2})[./-](\d{1,2})[./-](\d{2})(?!\d)"#, [2, 1, 0]),       // 14.10.26
        ]
        for (pattern, order) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let parts = (1...3).compactMap { index in
                    Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
                }
                guard parts.count == 3 else { continue }
                var year = parts[order[0]]
                if year < 100 { year += 2000 }
                var components = DateComponents()
                components.year = year
                components.month = parts[order[1]]
                components.day = parts[order[2]]
                guard let date = calendar.date(from: components),
                      calendar.component(.month, from: date) == components.month,
                      abs(date.timeIntervalSince(now)) < 2 * 366 * 86_400 else { continue }
                return date
            }
        }
        return nil
    }

    private static func merchant(in lines: [String]) -> String? {
        for line in lines.prefix(6) {
            let lower = line.lowercased()
            let letters = line.filter(\.isLetter).count
            guard letters >= 3, letters * 2 >= line.count,
                  !notAMerchant.contains(where: { lower.contains($0) }) else { continue }
            let trimmed = String(line.prefix(40)).trimmingCharacters(in: .whitespaces)
            // SHOUTING names are easier to read in normal case.
            return trimmed == trimmed.uppercased() ? trimmed.capitalized : trimmed
        }
        return nil
    }

    private static func category(for text: String) -> ExpenseCategory? {
        let lower = text.lowercased()
        let rules: [(ExpenseCategory, [String])] = [
            (.food, ["restaur", "café", "cafe", "kawiarnia", "bar ", "pizz", "burger", "bistro", "bakery", "piekarnia", "żabka",
                     "zabka", "biedronka", "lidl", "aldi", "spar", "carrefour", "supermarket", "gaststätte", "imbiss"]),
            (.transport, ["taxi", "uber", "bolt", "ztm", "bilet", "ticket", "bahn", "metro", "tram", "parking", "orlen", "shell", "bp "]),
            (.lodging, ["hotel", "hostel", "apart", "nocleg", "übernachtung"]),
            (.activities, ["muzeum", "museum", "zamek", "castle", "bilet wstępu", "eintritt", "admission", "tour"]),
            (.shopping, ["sklep", "shop", "store", "market", "mall", "souvenir", "apteka", "pharmacy", "rossmann", "hebe"]),
        ]
        let hits = rules.filter { rule in rule.1.contains { lower.contains($0) } }.map(\.0)
        return hits.first
    }
}
