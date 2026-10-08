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
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: weather.symbol)
                            .symbolRenderingMode(.multicolor)
                        Text(weather.summary)
                        Text("\(weather.rainChance)% rain")
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .font(Typography.label)
                    .foregroundStyle(Theme.ink)

                    if weather.isWet && outdoorStops > 0 {
                        Label("Rain likely, \(outdoorStops) outdoor \(outdoorStops == 1 ? "stop" : "stops") planned",
                              systemImage: "umbrella.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .card(padding: Spacing.m)
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
