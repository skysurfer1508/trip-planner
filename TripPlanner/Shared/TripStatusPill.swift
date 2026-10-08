import SwiftUI

/// "LIVE" for the trip that is happening today, otherwise the countdown or "Ended". Sits on photos:
/// LIVE is filled with the accent and says so in words, the others use a dark pill (white text over a
/// 0.55 black pill stays above 4.5:1 even on a white photo).
struct TripStatusPill: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if trip.isActiveToday {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(trip.isActiveToday ? "LIVE" : trip.statusText)
        }
        .font(Typography.eyebrow)
        .foregroundStyle(trip.isActiveToday ? Theme.onAccent : Color.white)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
        .background(trip.isActiveToday ? Theme.accent : Color.black.opacity(0.55), in: Capsule())
    }
}
