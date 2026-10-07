import SwiftUI
import MapKit

/// Numbered pins for a day's stops, joined by a line.
struct StopsMapView: View {
    let stops: [Stop]
    var showsUser = false
    var highlighted: Stop?
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
                            isHighlighted: highlighted?.persistentModelID == stop.persistentModelID)
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
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 3)
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

struct StopPin: View {
    let number: Int
    let category: StopCategory
    var isDone = false
    var isHighlighted = false
    var tint: Color?

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: isHighlighted ? 32 : 24, height: isHighlighted ? 32 : 24)
            .background(isDone ? Color.gray : (tint ?? category.color), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}
