import SwiftUI

/// Settings-like things only: saved places, sharing, editing the trip and the app's settings. The
/// trip tools (flights and hotel, packing, documents, practical info) live on Overview.
struct MoreView: View {
    @Bindable var trip: Trip

    @State private var showSaved = false
    @State private var showExport = false
    @State private var showEdit = false
    @State private var showSettings = false

    var body: some View {
        List {
            Section {
                row("Saved places", symbol: "bookmark",
                    detail: trip.savedPlaces.isEmpty ? nil : "\(trip.savedPlaces.count)") { showSaved = true }
                row("Share & export", symbol: "square.and.arrow.up") { showExport = true }
            } header: {
                Text("Trip").eyebrow()
            }

            Section {
                row("Edit name, destination and dates", symbol: "pencil") { showEdit = true }
            }

            Section {
                row("Settings and API keys", symbol: "gearshape") { showSettings = true }
            } header: {
                Text("App").eyebrow()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSaved) { SavedPlacesView(trip: trip) }
        .sheet(isPresented: $showExport) { ExportView(trip: trip) }
        .sheet(isPresented: $showEdit) { TripEditView(trip: trip) }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func row(_ title: String, symbol: String, detail: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InfoRow(symbol: symbol, title: title) {
                HStack(spacing: Spacing.s) {
                    if let detail {
                        Text(detail)
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
    }
}
