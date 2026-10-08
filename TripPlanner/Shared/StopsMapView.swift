import SwiftUI
import MapKit

/// Numbered pins for a day's stops, joined by a line.
struct StopsMapView: View {
    let stops: [Stop]
    var showsUser = false
    var highlighted: Stop?
    /// Index of the day being shown; picks the pin and route colour (`Theme.day`).
    var dayIndex = 0
    /// Called when a pin is tapped.
    var onSelect: ((Stop) -> Void)?
    /// Move the camera to the highlighted stop when it changes (used by the planner, not Trip Mode).
    var recenterOnHighlight = false
    /// The hotel the day starts from; the route line begins here.
    var start: CLLocationCoordinate2D?
    var startName: String?

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            if showsUser {
                UserAnnotation()
            }
            ForEach(Array(stops.enumerated()), id: \.element.persistentModelID) { index, stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    StopPin(number: index + 1,
                            category: stop.category,
                            isDone: stop.isDone,
                            isHighlighted: highlighted?.persistentModelID == stop.persistentModelID,
                            dayIndex: dayIndex)
                        .onTapGesture { onSelect?(stop) }
                        .accessibilityAddTraits(.isButton)
                }
            }
            if let start {
                Annotation(startName ?? "Hotel", coordinate: start) {
                    HotelPin()
                }
            }
            let path = (start.map { [$0] } ?? []) + stops.map(\.coordinate)
            if path.count > 1 {
                MapPolyline(coordinates: path)
                    .stroke(Theme.day(dayIndex).opacity(0.7), lineWidth: 3)
            }
        }
        .onChange(of: highlighted?.persistentModelID) { _, _ in
            guard recenterOnHighlight, let highlighted else { return }
            Motion.perform {
                camera = .region(MKCoordinateRegion(center: highlighted.coordinate,
                                                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            }
        }
        .mapControls {
            MapCompass()
            if showsUser {
                MapUserLocationButton()
            }
        }
    }
}

/// Thin wrapper over the design-system `Pin`, kept so existing call sites don't change.
struct StopPin: View {
    let number: Int
    let category: StopCategory
    var isDone = false
    var isHighlighted = false
    /// Index of the day this stop belongs to; picks the fill colour.
    var dayIndex = 0
    /// Show the category glyph badge (lists have room for it, maps don't).
    var showsCategory = false

    var body: some View {
        Pin(kind: .stop(number: number, day: dayIndex),
            category: showsCategory ? category : nil,
            isSelected: isHighlighted,
            isDone: isDone)
    }
}
