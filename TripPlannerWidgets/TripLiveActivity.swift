import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TripPlannerWidgets: WidgetBundle {
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
                        .foregroundStyle(.tint)
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
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT UP · \(tripName)")
                    .font(.caption2.bold())
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
