import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity is a separate target without the app's asset catalog, so it carries the two colours
/// it needs. Keep them equal to `Theme.accent` (light #0F7B6C, dark #4CC3A8) in the app.
private extension Color {
    static let tripAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x4C / 255, green: 0xC3 / 255, blue: 0xA8 / 255, alpha: 1)
            : UIColor(red: 0x0F / 255, green: 0x7B / 255, blue: 0x6C / 255, alpha: 1)
    })
}

@main
struct TripWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenView(tripName: context.attributes.tripName, state: context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.tripAccent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.stopName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let time = context.state.plannedTime {
                        Text(time, style: .time)
                            .font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.stopsLeft) \(context.state.stopsLeft == 1 ? "stop" : "stops") left today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "mappin.circle.fill")
            } compactTrailing: {
                if let time = context.state.plannedTime {
                    Text(time, style: .time)
                        .font(.caption2)
                        .frame(maxWidth: 52)
                } else {
                    Text("\(context.state.stopsLeft)")
                }
            } minimal: {
                Image(systemName: "mappin.circle.fill")
            }
        }
    }
}

private struct LockScreenView: View {
    let tripName: String
    let state: TripActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.largeTitle)
                .accessibilityHidden(true)
                .foregroundStyle(Color.tripAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next up · \(tripName)")
                    .font(.caption2.bold())
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(state.stopName)
                    .font(.headline)
                    .lineLimit(1)
                if let time = state.plannedTime {
                    HStack(spacing: 4) {
                        Text(time, style: .time)
                        Text("·")
                        Text(time, style: .relative)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(state.stopsLeft)\nleft")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
        }
    }
}
