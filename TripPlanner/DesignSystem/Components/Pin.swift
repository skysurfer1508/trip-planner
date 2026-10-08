import SwiftUI

/// What a pin stands for. One component draws all of them, on the map and in the timeline.
enum PinKind: Equatable {
    /// A numbered stop. `day` picks the fill colour (`Theme.day`).
    case stop(number: Int, day: Int)
    case hotel
    case end
    case entrance
    /// A transit station along a route. Small, not tappable.
    case station
}

/// The single pin style. Shapes and glyphs differ by kind, so colour is never the only cue:
/// - stop: solid day-colour circle with its number (a checkmark once done)
/// - hotel: ink circle with a bed
/// - end: ink circle with a flag
/// - entrance: outlined circle with a door
/// - station: small outlined dot
///
/// Pass `category` where there is room (the timeline) to add the stop's category glyph as a small
/// badge in the bottom corner. Sizes scale with Dynamic Type up to a cap.
struct Pin: View {
    let kind: PinKind
    var category: StopCategory?
    var isSelected = false
    var isDone = false

    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 30

    private var size: CGFloat { min(baseSize, 56) }

    var body: some View {
        ZStack {
            switch kind {
            case .stop(let number, let day):
                disc(fill: isDone ? Theme.inkSecondary : Theme.day(day)) {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.42, weight: .bold))
                    } else {
                        Text("\(number)")
                            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .contentTransition(.numericText())
                    }
                }
            case .hotel:
                disc(fill: Theme.ink) { glyph("bed.double.fill") }
            case .end:
                disc(fill: Theme.ink) { glyph("flag.checkered") }
            case .entrance:
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
                    .overlay(Image(systemName: "door.left.hand.open")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Theme.ink))
                    .frame(width: size, height: size)
            case .station:
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
                    .frame(width: size * 0.45, height: size * 0.45)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let category, case .stop = kind {
                Image(systemName: category.symbol)
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Theme.category(category))
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
                    .offset(x: size * 0.1, y: size * 0.1)
            }
        }
        .scaleEffect(isSelected ? 1.18 : 1)
        .elevation(isSelected ? .floating : .none)
        .motion(Motion.snappy, value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func disc<Content: View>(fill: Color, @ViewBuilder content: () -> Content) -> some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            .overlay(content().foregroundStyle(Theme.onAccent))
            .frame(width: size, height: size)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
    }

    private var accessibilityText: String {
        switch kind {
        case .stop(let number, _):
            let base = "Stop \(number)" + (category.map { ", \($0.title)" } ?? "")
            return isDone ? base + ", done" : base
        case .hotel: return "Hotel"
        case .end: return "End point"
        case .entrance: return "Entrance"
        case .station: return "Station"
        }
    }
}
