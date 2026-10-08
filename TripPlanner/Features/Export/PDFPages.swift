import SwiftUI

private let pageWidth: CGFloat = 595
private let pageHeight: CGFloat = 842
private let margin: CGFloat = 36

/// Shared frame of every page: white paper, margins, a small footer.
private struct PDFPage<Content: View>: View {
    let tripName: String
    let page: Int
    let total: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            Spacer(minLength: 0)
            HStack {
                Text(tripName)
                Spacer()
                Text("Page \(page) of \(total)")
            }
            .font(.system(size: 8))
            .foregroundStyle(.gray)
            .padding(.top, Spacing.s)
        }
        .padding(margin)
        .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color.black)
    }
}

struct PDFCoverPage: View {
    let cover: PDFCover
    let page: Int
    let total: Int
    let tripName: String

    var body: some View {
        PDFPage(tripName: tripName, page: page, total: total) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(cover.name)
                        .font(.system(size: 30, weight: .bold))
                    if !cover.destination.isEmpty {
                        Text(cover.destination)
                            .font(.system(size: 15))
                            .foregroundStyle(.gray)
                    }
                    Text("\(cover.dates) · \(cover.daysText)")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                }
                .padding(.bottom, Spacing.s)

                section("Flights and hotel", cover.bookings)

                if !cover.emergency.isEmpty {
                    section("Emergency numbers", cover.emergency.map { "Call \($0)" })
                }
                ForEach(Array(cover.notes.enumerated()), id: \.offset) { _, group in
                    section(group.title, group.items)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.gray)
                ForEach(items, id: \.self) { item in
                    Text("• " + item)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct PDFDayPage: View {
    let day: PDFDay
    let rows: [PDFStop]
    let isFirst: Bool
    let continued: Bool
    let page: Int
    let total: Int
    let tripName: String

    var body: some View {
        PDFPage(tripName: tripName, page: page, total: total) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.title + (continued ? " (continued)" : ""))
                        .font(.system(size: 22, weight: .bold))
                    Text(day.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }

                if isFirst {
                    if !day.holiday.isEmpty {
                        Text(day.holiday)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.orange)
                    }
                    ForEach(day.travel, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.gray)
                    }
                    if let map = day.map {
                        Image(uiImage: map)
                            .resizable()
                            .scaledToFill()
                            .frame(width: pageWidth - margin * 2, height: 190)
                            .clipShape(Radius.shape(Radius.small))
                    }
                    if !day.startFrom.isEmpty {
                        Label(day.startFrom, systemImage: "bed.double.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                }

                if day.stops.isEmpty {
                    Text("Nothing planned for this day.")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }

                ForEach(rows) { stop in
                    row(stop)
                    Divider()
                }
            }
        }
    }

    private func row(_ stop: PDFStop) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text("\(stop.number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.blue, in: Circle())

            Text(stop.time.isEmpty ? " " : stop.time)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.system(size: 12, weight: .semibold))
                if !stop.address.isEmpty {
                    Text(stop.address)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                }
                Text(stop.duration + (stop.hours.isEmpty ? "" : " · " + stop.hours))
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                if !stop.hoursWarning.isEmpty {
                    Text("! " + stop.hoursWarning)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                if !stop.notes.isEmpty {
                    Text(stop.notes)
                        .font(.system(size: 9.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)

            if let image = stop.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(Radius.shape(Radius.small))
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
