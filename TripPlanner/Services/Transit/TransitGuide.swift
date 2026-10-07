import Foundation

struct TransitNotes: Codable, Equatable {
    var tickets: [String] = []
    var apps: [String] = []
    var tips: [String] = []

    var isEmpty: Bool { tickets.isEmpty && apps.isEmpty && tips.isEmpty }
}

/// "How does public transport work here?": the "Get around" part of the destination's Wikivoyage page
/// (free, written by travellers, CC BY-SA). Optionally summarised by the AI, using only that text.
enum TransitGuide {
    struct Guide {
        var title: String
        var text: String
        var url: URL?
    }

    private static let api = "https://en.wikivoyage.org/w/api.php"

    /// "Lisbon, Portugal" -> ("Lisbon", "Portugal")
    static func parts(of destination: String) -> (city: String, country: String?) {
        let pieces = destination.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let city = pieces.first ?? destination
        return (city, pieces.count > 1 ? pieces.last : nil)
    }

    /// Picks the section to read: "By public transport" under "Get around", else "Get around" itself.
    /// `sections` are the entries of the MediaWiki `parse` result (`index`, `line`, `level`).
    static func pickSection(_ sections: [[String: Any]]) -> String? {
        func line(_ section: [String: Any]) -> String { (section["line"] as? String ?? "").lowercased() }
        func level(_ section: [String: Any]) -> Int { Net.int(section["level"]) ?? 0 }
        func index(_ section: [String: Any]) -> String? { section["index"] as? String ?? Net.int(section["index"]).map(String.init) }

        guard let start = sections.firstIndex(where: { line($0) == "get around" }) else { return nil }
        let base = level(sections[start])
        for section in sections[(start + 1)...] {
            if level(section) <= base { break }
            if line(section).contains("public transport") || line(section).contains("public transit") {
                return index(section)
            }
        }
        return index(sections[start])
    }

    /// Plain text from the HTML MediaWiki returns.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            ("<li[^>]*>", "\n• "), ("</p>", "\n\n"), ("<br\\s*/?>", "\n"), ("</h[1-6]>", "\n"), ("<h[1-6][^>]*>", "\n"),
            ("<style[^>]*>.*?</style>", ""), ("<script[^>]*>.*?</script>", ""), ("<[^>]+>", ""),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: [.regularExpression, .caseInsensitive])
        }
        let entities = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                        ("&#39;", "'"), ("&#160;", " "), ("[edit]", "")]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n[ ]+", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetch(destination: String) async -> Guide? {
        let names = parts(of: destination)
        if let guide = await fetch(page: names.city) { return guide }
        if let country = names.country, let guide = await fetch(page: country) { return guide }
        return nil
    }

    static func fetch(page: String) async -> Guide? {
        guard let sectionsURL = url(["action": "parse", "page": page, "prop": "sections", "format": "json",
                                     "formatversion": "2", "redirects": "1"]),
              let sectionsJSON = try? await Net.json(url: sectionsURL, session: Net.cached),
              let sections = (sectionsJSON["parse"] as? [String: Any])?["sections"] as? [[String: Any]],
              let index = pickSection(sections),
              let textURL = url(["action": "parse", "page": page, "section": index, "prop": "text",
                                 "format": "json", "formatversion": "2", "disableeditsection": "1", "redirects": "1"]),
              let textJSON = try? await Net.json(url: textURL, session: Net.cached),
              let html = (textJSON["parse"] as? [String: Any])?["text"] as? String else { return nil }

        let text = String(plainText(fromHTML: html).prefix(6_000))
        guard text.count > 80 else { return nil }
        let slug = page.replacingOccurrences(of: " ", with: "_")
        return Guide(title: page, text: text, url: URL(string: "https://en.wikivoyage.org/wiki/\(slug)#Get_around"))
    }

    private static func url(_ query: [String: String]) -> URL? {
        guard var components = URLComponents(string: api) else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    /// Loads the guide (and an AI summary when an engine is available) onto the trip, once.
    @MainActor
    static func ensure(for trip: Trip, geminiKey: String) async {
        if trip.transitGuide.isEmpty {
            guard !trip.destination.isEmpty, let guide = await fetch(destination: trip.destination) else { return }
            trip.transitGuide = guide.text
            trip.transitGuideTitle = guide.title
        }
        guard trip.transitNotes.isEmpty, !trip.transitGuide.isEmpty,
              let engine = AIRouter.current(geminiKey: geminiKey) else { return }
        let city = parts(of: trip.destination).city
        if let notes = try? await engine.summarizeTransit(text: trip.transitGuide, city: city), !notes.isEmpty,
           let data = try? JSONEncoder().encode(notes) {
            trip.transitNotes = String(decoding: data, as: UTF8.self)
        }
    }
}
