import SwiftUI

/// Destination photo from Wikipedia over a dark placeholder with a map glyph (shown while loading or
/// when there's no photo).
struct TripHeroImage: View {
    let trip: Trip
    @State private var hero: URL?

    var body: some View {
        Rectangle()
            .fill(Theme.photoFallback)
            .overlay {
                Image(systemName: "map")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
                    .accessibilityHidden(true)
            }
            .overlay {
                if let hero {
                    AsyncImage(url: hero) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        }
                    }
                }
            }
            .clipped()
            .task(id: trip.destination) {
                let city = trip.destination.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !city.isEmpty else {
                    hero = nil
                    return
                }
                hero = await WikipediaService.summary(title: city)?.hero
            }
    }
}
