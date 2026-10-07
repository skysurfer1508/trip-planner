import SwiftUI
import MapKit

/// Search sheet that returns the chosen place, used to fix a wrong or missing match.
/// Results appear while typing; places far from the trip's destination are listed separately.
struct PlacePickerView: View {
    @State var query: String
    let region: MKCoordinateRegion?
    let onPick: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var near: [MKMapItem] = []
    @State private var far: [MKMapItem] = []
    @State private var searched = false

    private var center: CLLocationCoordinate2D? { region?.center }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(near, id: \.self) { item in row(item) }
                }
                if !far.isEmpty {
                    Section {
                        ForEach(far.prefix(4), id: \.self) { item in row(item) }
                    } header: {
                        Text("Far from the destination")
                    }
                }
            }
            .overlay {
                if near.isEmpty && far.isEmpty && searched {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Choose place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) { await search() }
        }
    }

    private func row(_ item: MKMapItem) -> some View {
        Button {
            onPick(item)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Place")
                    .foregroundStyle(.primary)
                Text(subtitle(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func subtitle(_ item: MKMapItem) -> String {
        var parts: [String] = []
        if let center {
            parts.append(Format.distance(RoutingService.straightLine(from: center, to: item.placemark.coordinate)))
        }
        if let address = item.placemark.title, !address.isEmpty {
            parts.append(address)
        }
        return parts.joined(separator: " · ")
    }

    /// Searches while typing, after a short pause.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            near = []
            far = []
            searched = false
            return
        }
        // The first search (a name from the import) runs at once; typing waits for a pause.
        if searched {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        let items = (try? await PlaceSearchService.search(query: text, region: region)) ?? []
        guard !Task.isCancelled else { return }
        let split = PlaceSearchService.partition(items, around: center, within: 150_000)
        near = split.near
        far = split.far
        searched = true
    }
}
