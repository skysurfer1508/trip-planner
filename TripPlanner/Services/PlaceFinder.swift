import Foundation
import MapKit

/// Finds the place somebody means from a name that may be misspelt, partial, in another language or
/// described instead of named. Several spellings are tried on Apple Maps, results are ranked by how well
/// the name matches and how close they are to the destination, and when Apple Maps has nothing a second
/// free geocoder (Photon, built on OpenStreetMap) is asked.
enum PlaceFinder {
    struct Match: Identifiable {
        let id = UUID()
        let item: MKMapItem
        /// 0...1 overall, from name, distance and whether it is a known point of interest.
        let score: Double
        /// 0...1 how well the name matches what was asked for.
        let nameScore: Double

        /// Sure enough to pick without asking.
        var isConfident: Bool { nameScore >= 0.6 && score >= 0.55 }
    }

    // MARK: Name similarity (pure)

    private static let stopWords: Set<String> = [
        "the", "of", "a", "an", "and", "in", "at", "de", "la", "le", "el", "los", "las", "du", "des", "di", "da", "do",
        "der", "die", "das", "den", "von", "und", "y", "e", "i", "w", "na",
    ]

    /// Lowercase, no accents, and the letters that diacritic folding leaves alone (ł, ø, ß, đ, æ).
    static func fold(_ text: String) -> String {
        var result = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        for (from, to) in [("ł", "l"), ("ø", "o"), ("ß", "ss"), ("đ", "d"), ("æ", "ae"), ("œ", "oe"), ("ı", "i")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result.lowercased()
    }

    static func tokens(_ text: String) -> [String] {
        let words = fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { !stopWords.contains($0) }
        return meaningful.isEmpty ? words : meaningful
    }

    /// Edit distance, capped: enough to tell "swietokrzyski" from "swietokrzyska".
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[y.count]
    }

    /// Words match when they are equal, one starts with the other, or they differ by a letter or two.
    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        if shorter >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if shorter >= 5 { return distance(a, b) <= (shorter >= 9 ? 2 : 1) }
        return false
    }

    /// 0...1: how much of the asked-for name is in the found name (mostly), and the other way round.
    static func similarity(_ query: String, _ name: String) -> Double {
        let wanted = tokens(query)
        let found = tokens(name)
        guard !wanted.isEmpty, !found.isEmpty else { return 0 }
        let covered = wanted.filter { word in found.contains { wordsMatch(word, $0) } }.count
        let used = found.filter { word in wanted.contains { wordsMatch(word, $0) } }.count
        return 0.75 * Double(covered) / Double(wanted.count) + 0.25 * Double(used) / Double(found.count)
    }

    static func distanceScore(_ meters: Double) -> Double {
        switch meters {
        case ..<3_000: 1
        case ..<15_000: 0.8
        case ..<50_000: 0.4
        case ..<150_000: 0.1
        default: 0
        }
    }

    /// Name 65%, closeness to the destination 25%, known point of interest 10%.
    static func score(names: [String], placeName: String, coordinate: CLLocationCoordinate2D,
                      isPointOfInterest: Bool, center: CLLocationCoordinate2D?) -> (total: Double, name: Double) {
        let name = names.map { similarity($0, placeName) }.max() ?? 0
        let near = center.map { distanceScore(RoutingService.straightLine(from: $0, to: coordinate)) } ?? 0.7
        return (0.65 * name + 0.25 * near + (isPointOfInterest ? 0.1 : 0), name)
    }

    /// The spellings to try, best first: the name, other names, the name with the city.
    static func variants(name: String, alternatives: [String], city: String) -> [String] {
        let cityName = city.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var list: [String] = [name]
        list += alternatives
        if !cityName.isEmpty {
            for base in [name] + alternatives where !fold(base).contains(fold(cityName)) {
                list.append("\(base), \(cityName)")
            }
        }
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(fold($0)).inserted }
    }

    // MARK: Ranking a result list

    /// Orders results of one search by how well they fit the query and the destination.
    static func rank(_ items: [MKMapItem], query: String, center: CLLocationCoordinate2D?) -> [Match] {
        items.map { item in
            let result = score(names: [query], placeName: item.name ?? "",
                               coordinate: item.placemark.coordinate,
                               isPointOfInterest: item.pointOfInterestCategory != nil, center: center)
            return Match(item: item, score: result.total, nameScore: result.name)
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: Searching

    /// Free-text search for the search boxes: Apple Maps first, Photon when that finds nothing good.
    static func search(query: String, center: CLLocationCoordinate2D?, region: MKCoordinateRegion?) async -> [Match] {
        let apple = (try? await PlaceSearchService.search(query: query, region: region)) ?? []
        var matches = rank(apple, query: query, center: center)
        if (matches.first?.nameScore ?? 0) < 0.5 {
            let extra = await photon(query: query, center: center)
            matches = merge(matches, rank(extra, query: query, center: center))
        }
        return matches
    }

    /// The place for a name from a list: tries the variants until one match is confident.
    static func find(name: String, alternatives: [String] = [], center: CLLocationCoordinate2D?,
                     region: MKCoordinateRegion?, city: String) async -> [Match] {
        let names = [name] + alternatives
        var matches: [Match] = []

        func collect(_ items: [MKMapItem]) {
            let ranked = items.map { item -> Match in
                let result = score(names: names, placeName: item.name ?? "", coordinate: item.placemark.coordinate,
                                   isPointOfInterest: item.pointOfInterestCategory != nil, center: center)
                return Match(item: item, score: result.total, nameScore: result.name)
            }
            matches = merge(matches, ranked)
        }

        for query in variants(name: name, alternatives: alternatives, city: city).prefix(4) {
            collect((try? await PlaceSearchService.search(query: query, region: region)) ?? [])
            if matches.first?.isConfident == true && (matches.first?.score ?? 0) >= 0.75 { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        if matches.first?.isConfident != true {
            for query in names.prefix(2) {
                collect(await photon(query: query, center: center))
                if matches.first?.isConfident == true { break }
            }
        }
        return Array(matches.prefix(5))
    }

    /// Sorted by score, with the same place found twice kept once.
    static func merge(_ a: [Match], _ b: [Match]) -> [Match] {
        var result: [Match] = []
        for match in (a + b).sorted(by: { $0.score > $1.score }) {
            let duplicate = result.contains { existing in
                RoutingService.straightLine(from: existing.item.placemark.coordinate, to: match.item.placemark.coordinate) < 120
                    && similarity(existing.item.name ?? "", match.item.name ?? "") > 0.6
            }
            if !duplicate { result.append(match) }
        }
        return result
    }

    // MARK: Photon

    /// Places from Photon (OpenStreetMap data), biased towards `center`. Free, no key.
    static func photon(query: String, center: CLLocationCoordinate2D?) async -> [MKMapItem] {
        guard var components = URLComponents(string: "https://photon.komoot.io/api/") else { return [] }
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "6")]
        if let center {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.4f", center.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.4f", center.longitude)))
        }
        components.queryItems = items
        guard let url = components.url, let json = try? await Net.json(url: url, session: Net.cached) else { return [] }
        return parsePhoton(json)
    }

    static func parsePhoton(_ json: [String: Any]) -> [MKMapItem] {
        let features = json["features"] as? [[String: Any]] ?? []
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Double], coordinates.count >= 2,
                  let properties = feature["properties"] as? [String: Any],
                  let name = properties["name"] as? String, !name.isEmpty else { return nil }
            var address: [String: Any] = [:]
            let street = [properties["street"] as? String, properties["housenumber"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            if !street.isEmpty { address["Street"] = street }
            if let city = properties["city"] as? String { address["City"] = city }
            if let country = properties["country"] as? String { address["Country"] = country }
            let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: coordinates[1], longitude: coordinates[0]),
                                        addressDictionary: address.isEmpty ? nil : address)
            let item = MKMapItem(placemark: placemark)
            item.name = name
            return item
        }
    }
}
