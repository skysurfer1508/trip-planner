import SwiftUI

extension View {
    /// While the trip is live, floats a "Today" button above the tab bar that opens Trip Mode. It is the
    /// one tinted (primary) control on screen. Does nothing when the trip is not happening today.
    func todayShortcut(for trip: Trip) -> some View {
        modifier(TodayShortcut(trip: trip))
    }
}

private struct TodayShortcut: ViewModifier {
    let trip: Trip

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if trip.isActiveToday {
                NavigationLink {
                    TodayView(trip: trip)
                } label: {
                    Label("Today", systemImage: "location.fill")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 50)
                        .floatingChrome(tint: Theme.accent)
                        .elevation(.floating)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Spacing.l)
                .padding(.bottom, Spacing.s)
                .accessibilityLabel("Today, open Trip Mode")
            }
        }
    }
}
