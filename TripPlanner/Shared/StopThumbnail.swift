import SwiftUI

/// The photo of a stop, or its category icon when there is none yet.
struct StopThumbnail: View {
    let stop: Stop
    var size: CGFloat = 56
    var corner: CGFloat = 12

    var body: some View {
        Group {
            if let data = stop.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    stop.category.color.opacity(0.15)
                    Image(systemName: stop.category.symbol)
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(stop.category.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .accessibilityHidden(true)
    }
}

/// The hotel a day starts from. Thin wrapper over the design-system `Pin`.
struct HotelPin: View {
    var body: some View {
        Pin(kind: .hotel)
    }
}
