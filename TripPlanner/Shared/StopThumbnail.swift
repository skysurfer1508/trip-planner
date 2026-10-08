import SwiftUI

/// The photo of a stop, or its category icon when there is none yet.
struct StopThumbnail: View {
    let stop: Stop
    var size: CGFloat = 56
    var corner: CGFloat = Radius.small

    var body: some View {
        Group {
            if let data = stop.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Theme.category(stop.category).opacity(0.14)
                    Image(systemName: stop.category.symbol)
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(Theme.category(stop.category))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Radius.shape(corner))
        .accessibilityHidden(true)
    }
}

/// A wide photo of a stop (the Next up card), or a calm placeholder with its category glyph.
struct StopPhoto: View {
    let stop: Stop
    var height: CGFloat = 160

    var body: some View {
        // The picture goes in an overlay so that its aspect-fill size can't widen the layout: a fill
        // image reports the size it overflows to, which would make the whole page wider than the screen.
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let data = stop.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Theme.category(stop.category).opacity(0.14)
                        Image(systemName: stop.category.symbol)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.category(stop.category))
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// The hotel a day starts from. Thin wrapper over the design-system `Pin`.
struct HotelPin: View {
    var body: some View {
        Pin(kind: .hotel)
    }
}
