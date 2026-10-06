import SwiftUI

/// Destination photo from Wikipedia over a colour gradient (the gradient shows while loading or when
/// there's no photo).
struct TripHeroImage: View {
    let trip: Trip
    @State private var hero: URL?

    private var gradient: LinearGradient {
        let palette: [[Color]] = [
            [.indigo, .blue], [.teal, .green], [.orange, .pink], [.purple, .indigo], [.blue, .teal], [.pink, .orange],
        ]
        let seed = trip.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return LinearGradient(colors: palette[seed % palette.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Rectangle()
            .fill(gradient)
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

extension View {
    /// Rounded translucent card used on the Overview and Trip Mode screens.
    func card() -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
