import Foundation
import MapKit
import Observation

struct DraftStop: Identifiable {
    let id = UUID()
    var title: String
    var hour: Int?
    var minute: Int?
    var notes: String
    var category: StopCategory
    var item: MKMapItem?
    var include: Bool
}

struct DraftDay: Identifiable {
    let id = UUID()
    var label: String
    var date: Date?
    var targetIndex: Int
    var stops: [DraftStop]
}

/// Parsed stops waiting for the user's review, matched to Apple Maps places.
@Observable
final class ImportDraft {
    var days: [DraftDay] = []
    var progress = 0
    var total = 0

    var includedCount: Int {
        days.reduce(0) { sum, day in sum + day.stops.filter { $0.include && $0.item != nil }.count }
    }

    var unmatchedCount: Int {
        days.reduce(0) { sum, day in sum + day.stops.filter { $0.item == nil }.count }
    }

    /// Maps parsed days onto the trip's days: by date when the document has one, else in order.
    func load(_ itinerary: ParsedItinerary, tripDays: [Day]) {
        let calendar = Calendar.current
        days = itinerary.days.enumerated().map { index, parsed in
            var target = min(index, max(0, tripDays.count - 1))
            if let date = parsed.date,
               let match = tripDays.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                target = match
            }
            let stops = parsed.stops.map { stop in
                DraftStop(title: stop.title,
                          hour: stop.hour,
                          minute: stop.minute,
                          notes: stop.notes,
                          category: stop.category,
                          item: nil,
                          include: stop.confidence >= 0.5)
            }
            return DraftDay(label: parsed.label ?? "Day \(index + 1)",
                            date: parsed.date,
                            targetIndex: target,
                            stops: stops)
        }
    }

    /// Looks every stop up in Apple Maps, one after the other (MapKit throttles bursts).
    func resolveAll(center: CLLocationCoordinate2D?, region: MKCoordinateRegion?) async {
        total = days.reduce(0) { $0 + $1.stops.count }
        progress = 0

        for dayIndex in days.indices {
            for stopIndex in days[dayIndex].stops.indices {
                let title = days[dayIndex].stops[stopIndex].title
                if let item = await match(title, center: center, region: region) {
                    days[dayIndex].stops[stopIndex].item = item
                } else {
                    days[dayIndex].stops[stopIndex].include = false
                }
                progress += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func match(_ title: String,
                       center: CLLocationCoordinate2D?,
                       region: MKCoordinateRegion?) async -> MKMapItem? {
        guard let items = try? await PlaceSearchService.search(query: title, region: region) else { return nil }
        guard let center else { return items.first }
        // A match on the other side of the world is almost certainly wrong.
        return items.first { RoutingService.straightLine(from: center, to: $0.placemark.coordinate) < 200_000 }
    }
}
