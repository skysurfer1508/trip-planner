import SwiftUI

/// Packing, documents, saved places, sharing and settings.
struct MoreView: View {
    @Bindable var trip: Trip

    @State private var showSaved = false
    @State private var showExport = false
    @State private var showEdit = false
    @State private var showSettings = false

    var body: some View {
        List {
            Section("Trip tools") {
                NavigationLink {
                    BookingsView(trip: trip)
                } label: {
                    row("Flights & hotel", symbol: "airplane", detail: trip.bookings.isEmpty ? nil : "\(trip.bookings.count)")
                }
                NavigationLink {
                    PracticalInfoView(trip: trip)
                } label: {
                    row("Practical info", symbol: "info.circle", detail: trip.countryName.isEmpty ? nil : trip.countryName)
                }
                NavigationLink {
                    ChecklistView(trip: trip)
                } label: {
                    row("Packing & to-do", symbol: "checklist", detail: checklistDetail)
                }
                NavigationLink {
                    DocumentsView(trip: trip)
                } label: {
                    row("Documents", symbol: "folder", detail: "\(trip.documents.count)")
                }
                Button {
                    showSaved = true
                } label: {
                    row("Saved places", symbol: "bookmark", detail: "\(trip.savedPlaces.count)")
                }
                Button {
                    showExport = true
                } label: {
                    row("Share & export", symbol: "square.and.arrow.up", detail: nil)
                }
            }

            Section("Trip") {
                Button {
                    showEdit = true
                } label: {
                    row("Edit name, destination and dates", symbol: "pencil", detail: nil)
                }
            }

            Section("App") {
                Button {
                    showSettings = true
                } label: {
                    row("Settings and API keys", symbol: "gearshape", detail: nil)
                }
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSaved) { SavedPlacesView(trip: trip) }
        .sheet(isPresented: $showExport) { ExportView(trip: trip) }
        .sheet(isPresented: $showEdit) { TripEditView(trip: trip) }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var checklistDetail: String? {
        guard !trip.checklist.isEmpty else { return nil }
        return "\(trip.checklist.filter(\.isDone).count)/\(trip.checklist.count)"
    }

    private func row(_ title: String, symbol: String, detail: String?) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(.tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}
