import SwiftUI

/// A placeholder block shown while content loads, instead of a bare spinner. Swap it for the real
/// content as soon as it arrives. With Reduce Motion on it stays still.
///
/// This shimmer is the one animation in the app that repeats, and it only runs while loading.
struct SkeletonView: View {
    var height: CGFloat = 16
    var width: CGFloat?
    var radius: CGFloat = Radius.small

    var body: some View {
        Radius.shape(radius)
            .fill(Theme.separator.opacity(0.6))
            .frame(width: width, height: height)
            .modifier(Shimmer(radius: radius))
            .accessibilityHidden(true)
    }
}

private struct Shimmer: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Theme.surface.opacity(0.6), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: proxy.size.width * phase)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(Radius.shape(radius))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}
