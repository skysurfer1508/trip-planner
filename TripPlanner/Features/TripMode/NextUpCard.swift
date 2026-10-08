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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StopPhoto(stop: stop, height: 150)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Next up").eyebrow()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(stop.name)
                        .font(Typography.title)
                        .foregroundStyle(Theme.ink)
                    if let time = stop.plannedTime {
                        Label(Format.time(time), systemImage: "clock")
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if !stop.address.isEmpty {
                        Text(stop.address)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                    }
                }

                if !stop.summary.isEmpty {
                    Text(stop.summary)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
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
                            .font(Typography.headline)
                            .foregroundStyle(Theme.ink)
                    } else if distance != nil {
                        Label("Calculating…", systemImage: mode.symbol)
                            .font(Typography.headline)
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        Label("Turn on location for travel times", systemImage: "location.slash")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if let distance {
                        Text("· \(Format.distance(distance))")
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }

                if mode == .transit, let transitTrip, let origin {
                    TransitConnector(trip: transitTrip, fromName: "Your location", toName: stop.name,
                                     from: origin, to: stop.coordinate, timing: .now,
                                     fallback: "Looking for the best route…", inset: 0, liveRefresh: true,
                                     onDuration: { duration in transitDuration = duration },
                                     onBest: { best in
                                         liveBest = best
                                         Task { await scheduleLeaveReminder(for: best) }
                                     })
                }

                leaveBy

                actions
            }
            .padding(Spacing.l)
        }
        .background(Theme.surface)
        .clipShape(Radius.shape(Radius.card))
        .overlay(Radius.shape(Radius.card).strokeBorder(Theme.separator, lineWidth: 0.5))
        .elevation(.raised)
        .task { await PlaceInfoLoader.ensureInfo(for: stop) }
    }

    /// Navigate is the one primary action, Done sits next to it (stacked at accessibility text sizes).
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.s))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        return layout {
            Button {
                RoutingService.openInMaps(name: stop.name, coordinate: stop.coordinate, mode: mode)
            } label: {
                Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(.primary)

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.secondary)
        }
    }

    /// "Leave by 09:28" with the minutes left as a large number that ticks down. Urgent and late states
    /// change the icon and the words as well as the colour.
    @ViewBuilder
    private func leaveByLabel(leave: Date, minutes: Int, urgentAt: Int) -> some View {
        if minutes > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Label("Leave by \(Format.time(leave))", systemImage: "alarm")
                    .font(Typography.label)
                    .foregroundStyle(minutes <= urgentAt ? Theme.warning : Theme.inkSecondary)
                Text("in \(Format.minutes(minutes))")
                    .font(Typography.numeric)
                    .contentTransition(.numericText())
                    .foregroundStyle(minutes <= urgentAt ? Theme.warning : Theme.ink)
            }
        } else {
            Label(minutes == 0 ? "Time to leave" : "You're \(Format.minutes(-minutes)) behind",
                  systemImage: "exclamationmark.alarm")
                .font(Typography.headline)
                .foregroundStyle(Theme.danger)
        }
    }

    /// "Leave by 09:28 for the 09:35 tram +1": from the live departure, not the plan.
    private func liveLeaveBy(leave: Date, first: TransitLeg) -> some View {
        let zone = transitTrip?.timeZone ?? .current
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int((leave.timeIntervalSince(context.date) / 60).rounded(.down))
            VStack(alignment: .leading, spacing: 2) {
                leaveByLabel(leave: leave, minutes: minutes, urgentAt: 5)
                HStack(spacing: Spacing.xs) {
                    Text("for the")
                    LiveTime(date: first.departure, delay: first.departureDelayMinutes, cancelled: first.isCancelled, zone: zone)
                    Text(first.label)
                }
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
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
                leaveByLabel(leave: leave, minutes: minutes, urgentAt: 10)
            }
        }
    }
}
