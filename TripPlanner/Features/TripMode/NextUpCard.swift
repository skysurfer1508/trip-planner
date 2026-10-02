import SwiftUI
import CoreLocation

struct NextUpCard: View {
    let stop: Stop
    @Binding var mode: TravelMode
    let etas: [TravelMode: TimeInterval]
    let distance: CLLocationDistance?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEXT UP")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.name)
                        .font(.title2.bold())
                    if let time = stop.plannedTime {
                        Label(Format.time(time), systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !stop.address.isEmpty {
                        Text(stop.address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: stop.category.symbol)
                    .font(.title2)
                    .foregroundStyle(stop.category.color)
            }

            Picker("Travel mode", selection: $mode) {
                ForEach(TravelMode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if let eta = etas[mode] {
                    Label(Format.duration(eta), systemImage: mode.symbol)
                        .font(.headline)
                } else if distance != nil {
                    Label("Calculating…", systemImage: mode.symbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Turn on location for travel times", systemImage: "location.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let distance {
                    Text("· \(Format.distance(distance))")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    RoutingService.openInMaps(name: stop.name, coordinate: stop.coordinate, mode: mode)
                } label: {
                    Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDone) {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
