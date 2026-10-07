import Foundation

/// Hard facts about a country from Wikidata (CC0).
struct CountryFacts: Codable, Equatable {
    var name: String
    var callingCode: String?
    var voltage: String?
    var drivingSide: String?
    var emergency: [String] = []
    var currency: [String] = []
}

/// Short notes taken from the destination's Wikivoyage text; the AI only summarises that text.
struct PracticalNotes: Codable, Equatable {
    var emergency: [String] = []
    var safety: [String] = []
    var money: [String] = []
    var connectivity: [String] = []
    var electricity: [String] = []
    var health: [String] = []
    var etiquette: [String] = []

    var isEmpty: Bool {
        emergency.isEmpty && safety.isEmpty && money.isEmpty && connectivity.isEmpty
            && electricity.isEmpty && health.isEmpty && etiquette.isEmpty
    }
}

struct PracticalInfo: Codable, Equatable {
    var facts: CountryFacts?
    var notes: PracticalNotes?
    /// The Wikivoyage sections the notes came from, kept for offline reading.
    var guideText: String
    var guideTitle: String
    var fetchedAt: Date

    static func decode(_ json: String) -> PracticalInfo? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(PracticalInfo.self, from: Data(json.utf8))
    }

    /// The first thing worth showing in an emergency: numbers from Wikidata.
    var emergencyNumbers: [String] {
        facts?.emergency.filter { $0.contains(where: \.isNumber) } ?? []
    }
}

/// Country facts from Wikidata's SPARQL service (free, no key).
enum CountryFactsService {
    static func fetch(countryCode: String) async throws -> CountryFacts? {
        let code = countryCode.uppercased().filter(\.isLetter)
        guard code.count == 2 else { return nil }
        let query = """
        SELECT ?cLabel ?emergencyLabel ?currencyLabel ?sideLabel ?calling ?voltage WHERE {
          ?c wdt:P297 "\(code)".
          OPTIONAL { ?c wdt:P2852 ?emergency }
          OPTIONAL { ?c wdt:P38 ?currency }
          OPTIONAL { ?c wdt:P1622 ?side }
          OPTIONAL { ?c wdt:P474 ?calling }
          OPTIONAL { ?c wdt:P2884 ?voltage }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """
        guard var components = URLComponents(string: "https://query.wikidata.org/sparql") else { return nil }
        components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return nil }
        let json = try await Net.json(url: url, headers: ["Accept": "application/sparql-results+json"], session: Net.cached)
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> CountryFacts? {
        let bindings = (json["results"] as? [String: Any])?["bindings"] as? [[String: Any]] ?? []
        guard !bindings.isEmpty else { return nil }

        func values(_ key: String) -> [String] {
            var seen: [String] = []
            for row in bindings {
                guard let value = (row[key] as? [String: Any])?["value"] as? String else { continue }
                let text = value.trimmingCharacters(in: .whitespaces)
                // Entities without an English label come back as "Q4916".
                if text.isEmpty || text.range(of: "^Q\\d+$", options: .regularExpression) != nil { continue }
                if !seen.contains(text) { seen.append(text) }
            }
            return seen
        }

        return CountryFacts(name: values("cLabel").first ?? "",
                            callingCode: values("calling").first,
                            voltage: values("voltage").first,
                            drivingSide: values("sideLabel").first,
                            emergency: values("emergencyLabel"),
                            currency: values("currencyLabel"))
    }
}

/// Plain-text sections of Wikivoyage pages.
enum WikivoyageService {
    private static let api = "https://en.wikivoyage.org/w/api.php"

    /// The first section whose heading is one of `names` (e.g. "Stay safe").
    static func pickIndex(_ sections: [[String: Any]], named names: [String]) -> String? {
        let wanted = names.map { $0.lowercased() }
        for section in sections {
            let line = (section["line"] as? String ?? "").lowercased()
            guard wanted.contains(line) else { continue }
            if let index = section["index"] as? String { return index }
            if let index = Net.int(section["index"]) { return String(index) }
        }
        return nil
    }

    /// Text of the first matching section of a page, or nil if the page or section doesn't exist.
    static func text(page: String, named names: [String], limit: Int = 1_800) async -> String? {
        guard let sectionsURL = url(["action": "parse", "page": page, "prop": "sections", "format": "json",
                                     "formatversion": "2", "redirects": "1"]),
              let sectionsJSON = try? await Net.json(url: sectionsURL, session: Net.cached),
              let sections = (sectionsJSON["parse"] as? [String: Any])?["sections"] as? [[String: Any]],
              let index = pickIndex(sections, named: names),
              let textURL = url(["action": "parse", "page": page, "section": index, "prop": "text", "format": "json",
                                 "formatversion": "2", "disableeditsection": "1", "redirects": "1"]),
              let textJSON = try? await Net.json(url: textURL, session: Net.cached),
              let html = (textJSON["parse"] as? [String: Any])?["text"] as? String else { return nil }
        let text = String(TransitGuide.plainText(fromHTML: html).prefix(limit))
        return text.count > 40 ? text : nil
    }

    private static func url(_ query: [String: String]) -> URL? {
        guard var components = URLComponents(string: api) else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }
}

/// Loads the practical information of a trip's country once and keeps it on the trip.
@MainActor
enum PracticalInfoService {
    private static let sectionNames: [(label: String, names: [String])] = [
        ("Stay safe", ["Stay safe"]),
        ("Cope", ["Cope"]),
        ("Connect", ["Connect"]),
        ("Buy", ["Buy"]),
    ]

    static func ensure(for trip: Trip, geminiKey: String, force: Bool = false) async {
        _ = await TripTimeZone.ensure(trip)
        guard !trip.countryCode.isEmpty else { return }

        var info = PracticalInfo.decode(trip.practicalInfo)
        if info == nil || force {
            let facts = try? await CountryFactsService.fetch(countryCode: trip.countryCode)
            let guide = await guideText(for: trip)
            guard facts != nil || !guide.text.isEmpty else { return }
            info = PracticalInfo(facts: facts ?? nil, notes: nil, guideText: guide.text,
                                 guideTitle: guide.title, fetchedAt: Date())
        }
        guard var current = info else { return }

        if current.notes == nil || current.notes?.isEmpty == true,
           !current.guideText.isEmpty,
           let engine = AIRouter.current(geminiKey: geminiKey),
           let notes = try? await engine.summarizePractical(text: current.guideText,
                                                            country: trip.countryName.isEmpty ? trip.destination : trip.countryName),
           !notes.isEmpty {
            current.notes = notes
        }
        if let data = try? JSONEncoder().encode(current) {
            trip.practicalInfo = String(decoding: data, as: UTF8.self)
        }
    }

    /// "Stay safe", "Cope", "Connect" and "Buy" of the country page, plus "Stay safe" of the city page.
    private static func guideText(for trip: Trip) async -> (text: String, title: String) {
        let country = trip.countryName.isEmpty ? (TransitGuide.parts(of: trip.destination).country ?? "") : trip.countryName
        let city = TransitGuide.parts(of: trip.destination).city
        var blocks: [String] = []

        if !country.isEmpty {
            for section in sectionNames {
                if let text = await WikivoyageService.text(page: country, named: section.names) {
                    blocks.append("## \(country): \(section.label)\n\(text)")
                }
            }
        }
        if !city.isEmpty, city != country, let text = await WikivoyageService.text(page: city, named: ["Stay safe"], limit: 1_500) {
            blocks.append("## \(city): Stay safe\n\(text)")
        }
        return (String(blocks.joined(separator: "\n\n").prefix(7_000)), country.isEmpty ? city : country)
    }
}
