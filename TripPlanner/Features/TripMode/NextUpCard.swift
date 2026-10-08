import SwiftUI
import CoreLocation

struct NextUpCard: View {
    let stop: Stop
    @Binding var mode: TravelMode
    let etas: [TravelMode: TimeInterval]
    let distance: CLLocationDistance?
    /// With public transport selected, the real route from where you are is shown.
    var transitTrip: Trip?
    var origin: CLLocationCoordinate2D?
    @Binding var transitDuration: TimeInterval?
    let onDone: () -> Void

    @AppStorage("nudgesEnabled") private var nudgesEnabled = false
    /// The best connection, kept fresh while this card is on screen.
    @State private var liveBest: TransitItinerary?

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
                StopThumbnail(stop: stop, size: 72, corner: 14)
            }

            if !stop.summary.isEmpty {
                Text(stop.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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

            if mode == .transit, let transitTrip, let origin {
                TransitConnector(trip: transitTrip, fromName: "Your location", toName: stop.name,
                                 from: origin, to: stop.coordinate, timing: .now,
                                 fallback: "Looking for the best route…", liveRefresh: true,
                                 onDuration: { duration in transitDuration = duration },
                                 onBest: { best in
                                     liveBest = best
                                     Task { await scheduleLeaveReminder(for: best) }
                                 })
                .padding(.leading, -36)
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
        .task { await PlaceInfoLoader.ensureInfo(for: stop) }
    }

    /// "Leave by 09:28 for the 09:35 tram +1": from the live departure, not the plan.
    private func liveLeaveBy(leave: Date, first: TransitLeg) -> some View {
        let zone = transitTrip?.timeZone ?? .current
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int((leave.timeIntervalSince(context.date) / 60).rounded(.down))
            VStack(alignment: .leading, spacing: 2) {
                if minutes > 0 {
                    Label("Leave by \(Format.time(leave)) · in \(Format.minutes(minutes))", systemImage: "alarm")
                        .font(.subheadline.bold())
                        .foregroundStyle(minutes <= 5 ? Color.orange : Color.primary)
                } else {
                    Label(minutes == 0 ? "Time to leave" : "You're \(Format.minutes(-minutes)) behind",
                          systemImage: "exclamationmark.alarm")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                }
                HStack(spacing: 4) {
                    Text("for the")
                    LiveTime(date: first.departure, delay: first.departureDelayMinutes, cancelled: first.isCancelled, zone: zone)
                    Text(first.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// One reminder at the moment to leave, replaced whenever the live times change.
    private func scheduleLeaveReminder(for best: TransitItinerary?) async {
        guard nudgesEnabled, let best, let leave = TransitLive.leaveBy(best),
              let first = best.transitLegs.first else {
            await NudgeService.cancelLive()
            return
        }
        let text = "\(first.label) leaves at \(Format.time(first.departure ?? leave))" +
            (first.departureDelayMinutes.map { $0 > 0 ? " (\($0) min late)" : "" } ?? "")
        await NudgeService.scheduleLive(at: leave, title: "Time to head out", body: text)
    }

    /// "Leave by 14:35 (in 22 min)", turning red when it's time to go.
    @ViewBuilder
    private var leaveBy: some View {
        if mode == .transit, let best = liveBest, let leave = TransitLive.leaveBy(best),
           let first = best.transitLegs.first {
            liveLeaveBy(leave: leave, first: first)
        } else if let planned = stop.plannedTime,
           Calendar.current.isDateInToday(planned),
           let eta = (mode == .transit ? transitDuration : nil) ?? etas[mode] {
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
