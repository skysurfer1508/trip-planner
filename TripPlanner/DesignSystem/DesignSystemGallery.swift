#if DEBUG
import SwiftUI

/// Every token and component on one screen, for checking light, dark, Increase Contrast and large
/// Dynamic Type in the canvas or the simulator. Debug builds only.
struct DesignSystemGallery: View {
    @State private var selectedChip = 1
    @State private var filterOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text("Lisbon weekend").textRole(.display)
                Text("Day 2 · Sat 14 Jun").eyebrow()

                SectionHeader(title: "Banners", eyebrow: "Status")
                Banner(kind: .info, title: "Offline pack ready", message: "Maps and opening hours are saved on this phone.")
                Banner(kind: .warning, title: "Rain from 15:00", message: "Two outdoor stops are affected.") {
                    Button("Reorder day") {}.buttonStyle(.secondary(fullWidth: false))
                }
                Banner(kind: .danger, title: "Museum closed today")
                Banner(kind: .success, title: "Everything is booked")

                SectionHeader(title: "Chips", actionTitle: "See all") {}
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(0..<4, id: \.self) { index in
                            SelectableChip(title: ["Food", "Cafés", "Sights", "Bars"][index],
                                           symbol: ["fork.knife", "cup.and.saucer.fill", "camera.fill", "moon.stars.fill"][index],
                                           isOn: selectedChip == index) { selectedChip = index }
                        }
                    }
                }
                HStack(spacing: Spacing.s) {
                    Chip(title: "Open now", symbol: "clock")
                    Chip(title: "€€")
                    SelectableChip(title: "Walkable", isOn: filterOn) { filterOn.toggle() }
                }

                SectionHeader(title: "Card and rows")
                Card(elevation: .raised) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Next up").eyebrow()
                        Text("Pastéis de Belém").textRole(.title)
                        Text("Leave by 14:20").textRole(.numeric)
                        InfoRow(symbol: "airplane", title: "TP 1234 · LIS", detail: "Departs 08:15")
                        InfoRow(symbol: "bed.double", title: "Hotel Avenida", detail: "Check-in from 15:00") {
                            Image(systemName: "chevron.right").foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }

                SectionHeader(title: "Buttons")
                Button("Navigate") {}.buttonStyle(.primary)
                Button("Mark done") {}.buttonStyle(.secondary)
                Button("Disabled") {}.buttonStyle(.primary).disabled(true)

                SectionHeader(title: "Pins")
                HStack(spacing: Spacing.l) {
                    Pin(kind: .stop(number: 1, day: 0))
                    Pin(kind: .stop(number: 2, day: 1), category: .food)
                    Pin(kind: .stop(number: 3, day: 2), isSelected: true)
                    Pin(kind: .stop(number: 4, day: 3), isDone: true)
                    Pin(kind: .hotel)
                    Pin(kind: .end)
                    Pin(kind: .start)
                    Pin(kind: .entrance(boarding: true))
                    Pin(kind: .station(symbol: "tram.fill", large: true), tint: Theme.day(1))
                    Pin(kind: .station(symbol: nil, large: false), tint: Theme.day(1))
                }

                SectionHeader(title: "Days", eyebrow: "Solid fills")
                HStack(spacing: Spacing.s) {
                    ForEach(0..<Theme.dayColorCount, id: \.self) { day in
                        Pin(kind: .stop(number: day + 1, day: day))
                    }
                }
                SectionHeader(title: "Categories", eyebrow: "Glyph tints")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                    ForEach(StopCategory.allCases) { category in
                        Label(category.title, systemImage: category.symbol)
                            .font(Typography.label)
                            .foregroundStyle(category.color)
                    }
                }

                SectionHeader(title: "Loading")
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        SkeletonView(height: 20, width: 180)
                        SkeletonView(height: 14)
                        SkeletonView(height: 14, width: 120)
                    }
                }

                EmptyState(title: "No stops yet", systemImage: "mappin.slash",
                           message: "Add the first place for this day.", actionTitle: "Add place") {}
            }
            .padding(Spacing.l)
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(symbol: "fork.knife", label: "I'm hungry", isPrimary: true) {}
                .padding(Spacing.l)
        }
    }
}

#Preview("Light") {
    DesignSystemGallery()
}

#Preview("Dark") {
    DesignSystemGallery().preferredColorScheme(.dark)
}

#Preview("AX3") {
    DesignSystemGallery().dynamicTypeSize(.accessibility3)
}
#endif
