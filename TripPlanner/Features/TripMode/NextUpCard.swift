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

            leaveBy

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

    /// "Leave by 14:35 (in 22 min)", turning red when it's time to go.
    @ViewBuilder
    private var leaveBy: some View {
        if let planned = stop.plannedTime,
           Calendar.current.isDateInToday(planned),
           let eta = etas[mode] {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let leave = planned.addingTimeInterval(-(eta + 5 * 60))
                let minutes = Int((leave.timeIntervalSince(context.date) / 60).rounded(.down))
                if minutes > 0 {
                    Label("Leave by \(Format.time(leave)) · in \(Format.minutes(minutes))", systemImage: "alarm")
                        .font(.subheadline.bold())
                        .foregroundStyle(minutes <= 10 ? Color.orange : Color.primary)
                } else {
                    Label(minutes == 0 ? "Time to leave" : "You're \(Format.minutes(-minutes)) behind",
                          systemImage: "exclamationmark.alarm")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
