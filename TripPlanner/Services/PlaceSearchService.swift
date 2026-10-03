import MapKit

enum PlaceSearchService {
    /// Free-text place search, optionally biased to a region.
    static func search(query: String, region: MKCoordinateRegion?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region {
            request.region = region
        }
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }

    /// Finds a map region around a destination name like "Lisbon", used to bias place search.
    static func region(for destination: String) async -> MKCoordinateRegion? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return MKCoordinateRegion(center: item.placemark.coordinate,
                                  latitudinalMeters: 30_000,
                                  longitudinalMeters: 30_000)
    }

    /// Places around a point. With a query ("sushi restaurant") it runs a text search, otherwise
    /// it lists every place of the given categories. Results are sorted by distance.
    static func nearby(query: String?,
                       categories: [MKPointOfInterestCategory],
                       center: CLLocationCoordinate2D,
                       radius: CLLocationDistance) async throws -> [MKMapItem] {
        let filter = MKPointOfInterestFilter(including: categories)
        let items: [MKMapItem]

        if let query, !query.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: radius * 2,
                                                longitudinalMeters: radius * 2)
            request.pointOfInterestFilter = filter
            request.resultTypes = .pointOfInterest
            items = try await MKLocalSearch(request: request).start().mapItems
        } else {
            let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
            request.pointOfInterestFilter = filter
            items = try await MKLocalSearch(request: request).start().mapItems
        }

        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        func distance(_ item: MKMapItem) -> CLLocationDistance {
            let c = item.placemark.coordinate
            return origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
        }
        return items
            .filter { distance($0) <= radius * 1.2 }
            .sorted { distance($0) < distance($1) }
    }
}
