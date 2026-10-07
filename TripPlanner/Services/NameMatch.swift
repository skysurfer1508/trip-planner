import Foundation

/// Fuzzy matching of place names ("Hotel Sol Lisboa" ~ "Sol Lisboa"), ignoring accents,
/// punctuation and words every name has.
enum NameMatch {
    private static let genericWords: Set<String> = [
        "hotel", "hostel", "the", "and", "by", "apartments", "apartment", "residence", "resort", "inn", "bnb", "b&b",
    ]

    static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { !genericWords.contains($0) }
        return (meaningful.isEmpty ? words : meaningful).joined()
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let x = normalized(a)
        let y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let shorter = min(x.count, y.count)
        return shorter >= 4 && (x.contains(y) || y.contains(x))
    }
}
