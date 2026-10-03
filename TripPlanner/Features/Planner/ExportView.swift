import SwiftUI

/// Share the itinerary as text, or export stops with a time to the Calendar app.
struct ExportView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @State private var icsURL: URL?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ShareLink(item: ItineraryExporter.text(for: trip)) {
                        Label("Share itinerary as text", systemImage: "text.alignleft")
                    }
                } footer: {
                    Text("Day-by-day list with times, places and notes. Works in Messages, Mail, Notes and more.")
                }

                Section {
                    if let icsURL {
                        ShareLink(item: icsURL) {
                            Label("Export to Calendar (.ics)", systemImage: "calendar.badge.plus")
                        }
                    } else if loaded {
                        Text("Give stops a planned time to export them as calendar events.")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } footer: {
                    Text("Choose \"Calendar\" in the share sheet to add every timed stop as an event.")
                }
            }
            .navigationTitle("Share & export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                icsURL = ItineraryExporter.icsFile(for: trip)
                loaded = true
            }
        }
        .presentationDetents([.medium])
    }
}
