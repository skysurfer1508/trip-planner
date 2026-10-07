import SwiftUI
import MapKit
import UIKit

struct PDFOptions: Equatable {
    var maps = true
    var photos = true
    var notes = true
    var bookings = true
    var practical = true
}

struct PDFStop: Identifiable {
    let id = UUID()
    var number: Int
    var time: String
    var name: String
    var address: String
    var duration: String
    var notes: String
    var hours: String
    var hoursWarning: String
    var image: UIImage?
}

struct PDFDay: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var startFrom: String
    var travel: [String]
    var holiday: String
    var map: UIImage?
    var stops: [PDFStop]
}

struct PDFCover {
    var name: String
    var destination: String
    var dates: String
    var daysText: String
    var bookings: [String]
    var emergency: [String]
    var notes: [(title: String, items: [String])]
}

/// Page counts per day, so long days continue on a second page. Pure, so it is unit tested.
enum PDFPaginator {
    /// Splits `count` rows into pages: the first page has less room (header and map).
    static func pages(count: Int, firstCapacity: Int, nextCapacity: Int) -> [Range<Int>] {
        guard count > 0 else { return [0..<0] }
        var result: [Range<Int>] = []
        var start = 0
        var capacity = max(firstCapacity, 1)
        while start < count {
            let end = min(start + capacity, count)
            result.append(start..<end)
            start = end
            capacity = max(nextCapacity, 1)
        }
        return result
    }
}

/// Builds an A4 PDF of the whole trip: a cover page, one or more pages per day, and optional
/// practical information.
@MainActor
enum ItineraryPDF {
    static let pageSize = CGSize(width: 595, height: 842)

    // MARK: Data

    static func cover(for trip: Trip, options: PDFOptions) -> PDFCover {
        var bookings: [String] = []
        if options.bookings {
            for booking in trip.bookings.sorted(by: { $0.keyDate < $1.keyDate }) {
                let when = booking.keyDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                switch booking.kind {
                case .arrivalFlight: bookings.append("Flight \(booking.title) lands \(when) \(booking.placeName)")
                case .departureFlight: bookings.append("Flight \(booking.title) takes off \(when) \(booking.placeName)")
                case .hotel:
                    let out = booking.endDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    bookings.append("\(booking.title): check-in \(when), check-out \(out)\(booking.address.isEmpty ? "" : ", \(booking.address)")")
                }
            }
        }

        var emergency: [String] = []
        var notes: [(title: String, items: [String])] = []
        if options.practical, let info = PracticalInfo.decode(trip.practicalInfo) {
            emergency = info.emergencyNumbers
            if let found = info.notes {
                let groups: [(String, [String])] = [
                    ("Safety", found.safety), ("Money and tipping", found.money),
                    ("Phone and internet", found.connectivity), ("Electricity", found.electricity),
                    ("Health", found.health), ("Manners", found.etiquette),
                ]
                for group in groups where !group.1.isEmpty {
                    notes.append((title: group.0, items: group.1))
                }
            }
        }

        let dayCount = trip.days.count
        return PDFCover(name: trip.name,
                        destination: trip.destination,
                        dates: Format.dateRange(trip.startDate, trip.endDate),
                        daysText: "\(dayCount) \(dayCount == 1 ? "day" : "days")",
                        bookings: bookings,
                        emergency: emergency,
                        notes: notes)
    }

    static func days(for trip: Trip, options: PDFOptions) async -> [PDFDay] {
        var result: [PDFDay] = []
        for (index, day) in trip.sortedDays.enumerated() {
            let window = trip.window(for: day.date)
            let stops = day.sortedStops
            let holiday = trip.holiday(on: day.date).map { "Public holiday: \($0.name). Many places may be closed." } ?? ""

            let pdfStops: [PDFStop] = stops.enumerated().map { number, stop in
                var hours = ""
                var warning = ""
                if !stop.openingHours.isEmpty, let parsed = OpeningHours.parse(stop.openingHours) {
                    let date = stop.plannedTime ?? day.date
                    let holidayCheck: (Date) -> Bool = { trip.isNationalHoliday($0) }
                    let text = parsed.text(on: date, isHoliday: holidayCheck)
                    hours = text == "Closed" ? "Closed that day" : (text.hasPrefix("Not stated") ? "" : "Open " + text)
                    if let planned = stop.plannedTime,
                       let message = OpeningHours.warning(for: parsed.verdict(visitAt: planned, minutes: stop.durationMinutes, isHoliday: holidayCheck)) {
                        warning = message
                    }
                }
                return PDFStop(number: number + 1,
                               time: stop.plannedTime.map { Format.time($0) } ?? "",
                               name: stop.name,
                               address: stop.address,
                               duration: Format.minutes(stop.durationMinutes),
                               notes: options.notes ? stop.notes : "",
                               hours: hours,
                               hoursWarning: warning,
                               image: options.photos ? stop.imageData.flatMap { UIImage(data: $0) } : nil)
            }

            var map: UIImage?
            if options.maps, !stops.isEmpty {
                map = await DayMapSnapshot.image(stops: stops.map(\.coordinate), hotel: window.anchor,
                                                 size: CGSize(width: 523, height: 190))
            }

            result.append(PDFDay(title: "Day \(index + 1)",
                                 subtitle: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()),
                                 startFrom: window.anchorName.map { "Start from \($0)" } ?? "",
                                 travel: window.items.map { "\(TripLogistics.timeText($0.minute))  \($0.text)" },
                                 holiday: holiday,
                                 map: map,
                                 stops: pdfStops))
        }
        return result
    }

    // MARK: Pages and file

    static func pages(cover: PDFCover, days: [PDFDay], tripName: String) -> [AnyView] {
        var built: [(Int, Int) -> AnyView] = []
        built.append { page, total in AnyView(PDFCoverPage(cover: cover, page: page, total: total, tripName: tripName)) }

        for day in days {
            let hasMap = day.map != nil
            let ranges = PDFPaginator.pages(count: day.stops.count,
                                            firstCapacity: hasMap ? 4 : 6,
                                            nextCapacity: 8)
            for (index, range) in ranges.enumerated() {
                let rows = Array(day.stops[range])
                built.append { page, total in
                    AnyView(PDFDayPage(day: day, rows: rows, isFirst: index == 0, continued: index > 0,
                                       page: page, total: total, tripName: tripName))
                }
            }
        }
        let total = built.count
        return built.enumerated().map { $1($0 + 1, total) }
    }

    static func make(trip: Trip, options: PDFOptions) async -> URL? {
        let cover = cover(for: trip, options: options)
        let pageViews = pages(cover: cover, days: await days(for: trip, options: options), tripName: trip.name)

        let safeName = trip.name.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -")).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "Itinerary" : safeName)
            .appendingPathExtension("pdf")

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for view in pageViews {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }

    /// Opens the iOS print sheet for a PDF file.
    static func printPDF(at url: URL, jobName: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
    }
}

/// A map picture of a day (hotel, numbered stops, route line) for the PDF.
@MainActor
enum DayMapSnapshot {
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                                            longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.5, 0.01),
                                    longitudeDelta: max(((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.5, 0.01))
        return MKCoordinateRegion(center: center, span: span)
    }

    static func image(stops: [CLLocationCoordinate2D], hotel: CLLocationCoordinate2D?, size: CGSize) async -> UIImage? {
        let all = (hotel.map { [$0] } ?? []) + stops
        guard !all.isEmpty else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region(for: all)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        return UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)

            let line = UIBezierPath()
            for (index, coordinate) in all.enumerated() {
                let point = snapshot.point(for: coordinate)
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            UIColor.systemBlue.withAlphaComponent(0.8).setStroke()
            line.lineWidth = 3
            line.lineJoinStyle = .round
            line.stroke()

            if let hotel {
                pin(at: snapshot.point(for: hotel), text: "H", color: .systemIndigo)
            }
            for (index, coordinate) in stops.enumerated() {
                pin(at: snapshot.point(for: coordinate), text: "\(index + 1)", color: .systemBlue)
            }
        }
    }

    private static func pin(at point: CGPoint, text: String, color: UIColor) {
        let rect = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        color.setFill()
        UIBezierPath(ovalIn: rect).fill()
        UIColor.white.setStroke()
        let ring = UIBezierPath(ovalIn: rect)
        ring.lineWidth = 2
        ring.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }
}
