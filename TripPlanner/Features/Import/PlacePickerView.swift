import SwiftUI
import MapKit

/// Search sheet that returns the chosen place, used to fix a wrong or missing match.
struct PlacePickerView: View {
    @State var query: String
    let region: MKCoordinateRegion?
    let onPick: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var results: [MKMapItem] = []
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Place")
                            .foregroundStyle(.primary)
                        if let address = item.placemark.title {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .overlay {
                if results.isEmpty && searched {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Choose place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await search() }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        results = (try? await PlaceSearchService.search(query: text, region: region)) ?? []
        searched = true
    }
}
