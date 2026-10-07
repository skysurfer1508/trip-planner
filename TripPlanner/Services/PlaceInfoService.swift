import Foundation
import CoreLocation

struct PlaceInfo {
    var title: String
    var summary: String
    var pageURL: URL?
    var imageURL: URL?
}

enum PlaceLookupResult {
    case found(PlaceInfo)
    case notFound
    case failed
}

/// Finds a photo and a short description for a place from Wikipedia: first the article tagged at
/// that spot whose title matches the name, then an article with exactly that name.
enum PlaceInfoService {
    private static let skippedPrefixes = ["Land ·", "Check in", "Check out", "Leave for the airport", "Flight "]

    static func shouldLookUp(name: String, category: StopCategory) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return !skippedPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// The device language first (when it isn't English), then English.
    static func languages() -> [String] {
        var list: [String] = []
        if let code = Locale.current.language.languageCode?.identifier, code != "en" {
            list.append(code)
        }
        list.append("en")
        return list
    }

    /// Chooses the article for a place: a title that matches its name, or for sights the article
    /// tagged within 60 m (the article may use another language's name for the place).
    static func pickTitle(from hits: [WikiHit], name: String, allowNearest: Bool) -> String? {
        if let match = hits.first(where: { NameMatch.similar($0.title, name) }) {
            return match.title
        }
        if allowNearest, let closest = hits.min(by: { $0.distance < $1.distance }), closest.distance <= 60 {
            return closest.title
        }
        return nil
    }

    /// Two or three sentences instead of a whole paragraph.
    static func shorten(_ text: String, limit: Int = 420) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let head = String(cleaned.prefix(limit))
        if let end = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: end.upperBound) > limit / 3 {
            return String(head[..<end.lowerBound]) + "."
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func lookup(name: String, coordinate: CLLocationCoordinate2D, category: StopCategory) async -> PlaceLookupResult {
        let allowNearest = category == .sight || category == .other
        var hadError = false

        for language in languages() {
            do {
                // 1. The article tagged at this spot.
                let hits = try await WikipediaService.nearbyArticles(coordinate: coordinate, radius: 400, language: language)
                if let title = pickTitle(from: hits, name: name, allowNearest: allowNearest),
                   let summary = try await WikipediaService.fetchSummary(title: title, language: language),
                   isUsable(summary) {
                    return .found(info(from: summary))
                }
                // 2. An article called exactly like the place, if it is really there.
                if let summary = try await WikipediaService.fetchSummary(title: name, language: language),
                   isUsable(summary), isNear(summary, coordinate: coordinate, name: name) {
                    return .found(info(from: summary))
                }
            } catch {
                hadError = true
            }
        }
        return hadError ? .failed : .notFound
    }

    private static func isUsable(_ summary: WikiSummary) -> Bool {
        summary.type != "disambiguation" && !summary.extract.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isNear(_ summary: WikiSummary, coordinate: CLLocationCoordinate2D, name: String) -> Bool {
        if let tagged = summary.coordinate {
            return RoutingService.straightLine(from: tagged, to: coordinate) < 3_000
        }
        return NameMatch.similar(summary.title, name)
    }

    private static func info(from summary: WikiSummary) -> PlaceInfo {
        PlaceInfo(title: summary.title,
                  summary: shorten(summary.extract),
                  pageURL: summary.pageURL,
                  imageURL: summary.thumbnailURL(width: 640))
    }
}
