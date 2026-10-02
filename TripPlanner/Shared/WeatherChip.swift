import SwiftUI
import CoreLocation

/// Forecast for one day, with a rain warning when outdoor stops are planned.
struct WeatherChip: View {
    let date: Date
    let coordinate: CLLocationCoordinate2D?
    var outdoorStops = 0

    @State private var weather: DayWeather?

    private var taskKey: String {
        let lat = coordinate.map { String(format: "%.2f", $0.latitude) } ?? "-"
        let lon = coordinate.map { String(format: "%.2f", $0.longitude) } ?? "-"
        return "\(date.timeIntervalSince1970)-\(lat)-\(lon)"
    }

    var body: some View {
        Group {
            if let weather {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: weather.symbol)
                            .symbolRenderingMode(.multicolor)
                        Text(weather.summary)
                        Text("\(weather.rainChance)% rain")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    if weather.isWet && outdoorStops > 0 {
                        Label("Rain likely, \(outdoorStops) outdoor \(outdoorStops == 1 ? "stop" : "stops") planned",
                              systemImage: "umbrella.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: taskKey) {
            guard let coordinate else {
                weather = nil
                return
            }
            weather = await WeatherService.forecast(for: date, at: coordinate)
        }
    }
}
