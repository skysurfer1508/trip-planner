import Foundation
import SwiftData

/// Fills in a stop's photo and description once and keeps them on the stop, so they work offline.
@MainActor
enum PlaceInfoLoader {
    private static var inFlight = Set<PersistentIdentifier>()
    /// Limits how many lookups run at once when a long list of stops appears.
    static let gate = RequestGate(limit: 3)

    /// Does nothing if the stop was already looked up (unless `force`). A photo the user chose
    /// is never replaced.
    static func ensureInfo(for stop: Stop, force: Bool = false) async {
        guard PlaceInfoService.shouldLookUp(name: stop.name, category: stop.category) else { return }
        if !force && stop.infoCheckedAt != nil { return }
        let id = stop.persistentModelID
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let name = stop.name
        let coordinate = stop.coordinate
        let category = stop.category

        do { try await gate.enter() } catch { return }
        let result = await PlaceInfoService.lookup(name: name, coordinate: coordinate, category: category)
        await gate.leave()

        // The stop may have been deleted while waiting.
        guard stop.modelContext != nil else { return }

        switch result {
        case .failed:
            return
        case .notFound:
            stop.infoCheckedAt = Date()
        case .found(let info):
            if stop.summary.isEmpty || force {
                stop.summary = info.summary
            }
            stop.wikiURL = info.pageURL?.absoluteString ?? ""
            if let id = info.wikidataID { stop.wikidataID = id }
            if stop.imageSource != "user", let url = info.imageURL,
               let data = try? await Net.bytes(url: url, session: Net.cached), stop.modelContext != nil {
                stop.imageData = data
                stop.imageSource = "wikipedia"
            }
            stop.infoCheckedAt = Date()
        }
    }
}
