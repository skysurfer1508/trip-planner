import SwiftUI

/// How tall the planner's map is: a thin strip, about a third of the screen, or most of it.
enum MapDetent: CaseIterable {
    case strip, half, full

    var title: String {
        switch self {
        case .strip: "Collapsed"
        case .half: "Half height"
        case .full: "Expanded"
        }
    }

    var next: MapDetent {
        switch self {
        case .strip: .half
        case .half: .full
        case .full: .strip
        }
    }
}

/// A map above the timeline that can be dragged between three heights. Drag the handle under it, tap it
/// to step to the next height, or use the VoiceOver adjust action. With Reduce Motion the height
/// changes without animating.
struct DetentMapPanel<Content: View>: View {
    @Binding var detent: MapDetent
    /// Height of the whole planner area; the detents are fractions of it.
    let availableHeight: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var drag: CGFloat = 0

    private func height(for detent: MapDetent) -> CGFloat {
        switch detent {
        case .strip: 84
        case .half: max(220, availableHeight * 0.34)
        case .full: max(320, availableHeight * 0.62)
        }
    }

    private var current: CGFloat {
        min(max(height(for: detent) + drag, height(for: .strip)), height(for: .full))
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(height: current)
                .clipped()
                .allowsHitTesting(detent != .strip)
            handle
        }
    }

    private var handle: some View {
        Capsule()
            .fill(Theme.inkSecondary.opacity(0.6))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.background)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        let projected = current + (value.predictedEndTranslation.height - value.translation.height) * 0.25
                        let target = MapDetent.allCases.min {
                            abs(height(for: $0) - projected) < abs(height(for: $1) - projected)
                        } ?? detent
                        Motion.perform {
                            drag = 0
                            if target != detent {
                                Haptics.select()
                                detent = target
                            }
                        }
                    }
            )
            .onTapGesture {
                Haptics.select()
                Motion.perform { detent = detent.next }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map size")
            .accessibilityValue(detent.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: Motion.perform { detent = detent == .strip ? .half : .full }
                case .decrement: Motion.perform { detent = detent == .full ? .half : .strip }
                @unknown default: break
                }
            }
    }
}
