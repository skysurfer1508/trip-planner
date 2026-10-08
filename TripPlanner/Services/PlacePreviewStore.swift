import Foundation
import CoreLocation
import Observation
import SwiftUI

/// What is known about a place that is not a saved stop yet (Auto plan, review): its photo and
/// a short description from Wikipedia.
struct PlacePreview {
    var summary = ""
    var wikiURL = ""
    var imageData: Data?
}

/// Looks previews up once per place and remembers them while the app runs. When the plan is
/// added to the trip, the previews are copied onto the new stops, so nothing is fetched twice.
@MainActor
@Observable
final class PlacePreviewStore {
    static let shared = PlacePreviewStore()

    private(set) var previews: [String: PlacePreview] = [:]
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private let gate = RequestGate(limit: 3)

    nonisolated static func key(name: String, coordinate: CLLocationCoordinate2D) -> String {
        "\(name.lowercased())|" + String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    func preview(name: String, coordinate: CLLocationCoordinate2D) -> PlacePreview? {
        previews[Self.key(name: name, coordinate: coordinate)]
    }

    func load(name: String, coordinate: CLLocationCoordinate2D, category: StopCategory) async {
        guard PlaceInfoService.shouldLookUp(name: name, category: category) else { return }
        let key = Self.key(name: name, coordinate: coordinate)
        guard !requested.contains(key) else { return }
        requested.insert(key)

        do {
            try await gate.enter()
        } catch {
            requested.remove(key)      // cancelled while waiting: asked for again when shown again
            return
        }
        let result = await PlaceInfoService.lookup(name: name, coordinate: coordinate, category: category)
        await gate.leave()

        switch result {
        case .failed:
            // Try again next time the place is shown.
            requested.remove(key)
        case .notFound:
            previews[key] = PlacePreview()
        case .found(let info):
            var preview = PlacePreview(summary: info.summary, wikiURL: info.pageURL?.absoluteString ?? "")
            previews[key] = preview
            if let url = info.imageURL, let data = try? await Net.bytes(url: url, session: Net.cached) {
                preview.imageData = data
                previews[key] = preview
            }
        }
    }

    /// Copies a known preview onto a stop that was just created from the plan.
    func apply(to stop: Stop) {
        guard let preview = preview(name: stop.name, coordinate: stop.coordinate),
              stop.infoCheckedAt == nil else { return }
        stop.summary = preview.summary
        stop.wikiURL = preview.wikiURL
        if let data = preview.imageData {
            stop.imageData = data
            stop.imageSource = "wikipedia"
        }
        stop.infoCheckedAt = Date()
    }
}

extension View {
    /// Loads the photo and description of a place that is shown in a list.
    func loadsPlacePreview(name: String, coordinate: CLLocationCoordinate2D, category: StopCategory) -> some View {
        task(id: PlacePreviewStore.key(name: name, coordinate: coordinate)) {
            await PlacePreviewStore.shared.load(name: name, coordinate: coordinate, category: category)
        }
    }
}

/// The photo of a planned place, or its category icon until there is one.
struct PlaceThumbnail: View {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let category: StopCategory
    var size: CGFloat = 56
    var corner: CGFloat = 12

    var body: some View {
        Group {
            if let data = PlacePreviewStore.shared.preview(name: name, coordinate: coordinate)?.imageData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    category.color.opacity(0.15)
                    Image(systemName: category.symbol)
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(category.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .accessibilityHidden(true)
    }
}

/// The short description of a planned place, when there is one.
struct PlaceSummaryText: View {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var lines = 3

    var body: some View {
        if let summary = PlacePreviewStore.shared.preview(name: name, coordinate: coordinate)?.summary,
           !summary.isEmpty {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
        }
    }
}
