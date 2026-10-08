import SwiftUI

/// First run: what the app does, then why it asks for location and for notifications, right before the
/// system asks. Every step can be skipped, and nothing is requested until its button is tapped.
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(LocationService.self) private var location
    @State private var page = 0
    @State private var movingForward = true
    @Environment(\.dynamicTypeSize) private var typeSize

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                progress
                Spacer(minLength: Spacing.m)
                Button("Skip", action: onFinish)
                    .font(Typography.label)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)

            ZStack {
                switch page {
                case 0: welcome
                case 1: locationPage
                default: reminders
                }
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
        }
        .motion(Motion.state, value: page)
        .background(Theme.background)
    }

    // MARK: Pages

    private var welcome: some View {
        pageLayout(symbol: "map",
                   title: "Plan every day, follow it on the road",
                   message: nil) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                InfoRow(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                        title: "A timeline for each day",
                        detail: "With walking, transit and driving times between stops.")
                InfoRow(symbol: "location.fill",
                        title: "Trip Mode",
                        detail: "Shows what's next and when to leave.")
                InfoRow(symbol: "lock",
                        title: "Your trips stay on this iPhone",
                        detail: "No account, and it works offline.")
            }
        } actions: {
            Button("Continue") { go(to: 1) }
                .buttonStyle(.primary)
        }
    }

    private var locationPage: some View {
        pageLayout(symbol: "location.fill",
                   title: "Directions from where you are",
                   message: "Your location is used to show how long it takes to reach your next stop and to find places nearby. It is only read while the app is open, and it never leaves your iPhone.") {
            EmptyView()
        } actions: {
            Button("Allow location") {
                location.start()
                go(to: 2)
            }
            .buttonStyle(.primary)
            Button("Not now") { go(to: 2) }
                .buttonStyle(.secondary)
        }
    }

    private var reminders: some View {
        pageLayout(symbol: "bell.badge",
                   title: "A nudge when it's time to leave",
                   message: "Trip Mode can remind you shortly before you need to head to the next stop, and before flights. You can change this later in Settings.") {
            EmptyView()
        } actions: {
            Button("Turn on reminders") {
                Task {
                    _ = await NudgeService.requestAuthorization()
                    onFinish()
                }
            }
            .buttonStyle(.primary)
            Button("Not now", action: onFinish)
                .buttonStyle(.secondary)
        }
    }

    // MARK: Layout

    private func pageLayout<Extra: View, Actions: View>(
        symbol: String, title: String, message: String?,
        @ViewBuilder extra: () -> Extra, @ViewBuilder actions: () -> Actions
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Image(systemName: symbol)
                    .font(.system(size: typeSize.isAccessibilitySize ? 44 : 64, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, Spacing.xl)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typography.display)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Theme.inkSecondary)
                }
                extra()
            }
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.s) {
                actions()
            }
            .padding(Spacing.l)
            .background(Theme.background)
        }
    }

    private var progress: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index <= page ? Theme.accent : Theme.separator)
                    .frame(width: index == page ? 28 : 10, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(page + 1) of \(pageCount)")
    }

    private func go(to target: Int) {
        movingForward = target > page
        Motion.perform { page = target }
    }
}
