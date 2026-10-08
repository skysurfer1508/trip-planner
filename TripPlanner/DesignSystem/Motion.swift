import SwiftUI
import UIKit

/// Motion spec. One spring for state changes, short fades for content, nothing that loops.
/// (The single exception is the skeleton shimmer, which runs only while something is loading.)
///
/// Every animation must go through `.motion(_:value:)` or `Motion.perform(...)` so that Reduce Motion
/// turns it into an instant change.
enum Motion {
    /// State changes: selection, expand/collapse, reorder, sheet detents.
    static let state: Animation = .smooth(duration: 0.35)
    /// Quick, direct feedback: presses, toggles, chips.
    static let snappy: Animation = .snappy(duration: 0.25)
    /// Content appearing or swapping.
    static let fade: Animation = .easeInOut(duration: 0.15)

    /// Runs `body` with `animation`, or without animation when Reduce Motion is on.
    @MainActor
    static func perform(_ animation: Animation = Motion.state, _ body: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            body()
        } else {
            withAnimation(animation, body)
        }
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation = Motion.state, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

/// Haptics. Call from button actions and gestures, never from `body`.
@MainActor
enum Haptics {
    /// A selection changed (chip, segmented control, picker).
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A physical-feeling bump (pick up or drop a row, tap a floating button).
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Something completed (stop done, item packed, stop added).
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A warning or a destructive step.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
