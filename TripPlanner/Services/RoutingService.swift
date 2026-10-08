import MapKit

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, transit, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: "Walk"
        case .transit: "Transit"
        case .drive: "Drive"
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .transit: "tram.fill"
        case .drive: "car.fill"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .walk: .walking
        case .transit: .transit
        case .drive: .automobile
        }
    }

    var launchMode: String {
        switch self {
        case .walk: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .drive: MKLaunchOptionsDirectionsModeDriving
        }
    }

    /// Average speed in m/s, used when Apple Maps can't give an ETA.
    var fallbackSpeed: Double {
        switch self {
        case .walk: 1.3
        case .transit: 6
        case .drive: 9
        }
    }
}

enum RoutingService {
    /// Real travel time from Apple Maps, or nil if no route is available.
    static func eta(from: CLLocationCoordinate2D,
                    to: CLLocationCoordinate2D,
                    mode: TravelMode) async -> TimeInterval? {
        guard await MapKitThrottle.shared.acquire() else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = mode.transportType
        do {
            let response = try await MKDirections(request: request).calculateETA()
            return response.expectedTravelTime
        } catch {
            return nil
        }
    }

    static func straightLine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    /// Rough travel time from the straight-line distance (streets are about 25% longer).
    static func estimate(from: CLLocationCoordinate2D,
                         to: CLLocationCoordinate2D,
                         mode: TravelMode) -> TimeInterval {
        straightLine(from: from, to: to) * 1.25 / mode.fallbackSpeed
    }

    /// Opens Apple Maps with turn-by-turn directions.
    static func openInMaps(name: String, coordinate: CLLocationCoordinate2D, mode: TravelMode) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launchMode])
    }
}
