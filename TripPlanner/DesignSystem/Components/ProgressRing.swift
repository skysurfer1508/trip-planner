import SwiftUI

/// A thin ring that fills clockwise, for "2 of 5 done" style progress. The value is also spoken.
struct ProgressRing: View {
    /// 0...1
    let progress: Double
    var lineWidth: CGFloat = 5

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.separator, lineWidth: lineWidth)
            if clamped > 0 {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .motion(Motion.state, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}
