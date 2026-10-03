import MapKit
import Observation

struct ResolvedDestination {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// Type-ahead for destinations ("Lis" -> "Lisbon, Portugal") using Apple Maps.
@Observable
final class DestinationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            suggestions = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    func clear() {
        suggestions = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Street addresses have numbers in the title; destinations are cities, regions, countries.
        suggestions = completer.results
            .filter { !$0.title.contains(where: \.isNumber) }
            .prefix(5)
            .map { $0 }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }

    static func displayName(_ completion: MKLocalSearchCompletion) -> String {
        completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)"
    }

    /// Looks up the coordinate of a picked suggestion.
    static func resolve(_ completion: MKLocalSearchCompletion) async -> ResolvedDestination? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return ResolvedDestination(name: displayName(completion), coordinate: item.placemark.coordinate)
    }

    /// Looks up a destination that was typed without picking a suggestion.
    static func resolve(text: String) async -> ResolvedDestination? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return ResolvedDestination(name: trimmed, coordinate: item.placemark.coordinate)
    }
}
