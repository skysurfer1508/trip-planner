import SwiftUI

/// Share the itinerary as text, or export stops with a time to the Calendar app.
struct ExportView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @State private var icsURL: URL?
    @State private var tripFileURL: URL?
    @State private var includeDocuments = false
    @State private var loaded = false
    @State private var calendarMessage: String?
    @State private var adding = false

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
                    NavigationLink {
                        PDFExportView(trip: trip)
                    } label: {
                        Label("PDF itinerary (save or print)", systemImage: "doc.richtext")
                    }
                } footer: {
                    Text("A clean day-by-day document with maps, times and addresses.")
                }

                Section {
                    if let tripFileURL {
                        ShareLink(item: tripFileURL) {
                            Label("Send the trip file", systemImage: "paperplane")
                        }
                    } else {
                        ProgressView()
                    }
                    Toggle("Include documents (tickets, bookings)", isOn: $includeDocuments)
                } footer: {
                    Text("A .tripplanner file with everything: days, stops, budget and packing list. Friends with the app can open it from Messages, AirDrop or Files and get their own copy. It also works as a backup.")
                }

                Section {
                    if let icsURL {
                        ShareLink(item: icsURL) {
                            Label("Export to Calendar (.ics)", systemImage: "calendar.badge.plus")
                        }
                    } else if loaded {
                        Text("Give stops a planned time to export them as calendar events.")
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        ProgressView()
                    }
                } footer: {
                    Text("Timed stops, flights and your hotel check-in become events with the place and a reminder, at the right time for the destination. Choose \"Calendar\" in the share sheet, or add them straight away.")
                }

                Section {
                    Button {
                        Task { await addToCalendar() }
                    } label: {
                        HStack {
                            Label("Add to Calendar", systemImage: "calendar.badge.checkmark")
                            Spacer()
                            if adding { ProgressView() }
                        }
                    }
                    .disabled(adding || icsURL == nil)
                    if let calendarMessage {
                        Text(calendarMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } footer: {
                    Text("The app only asks to add events; it never reads your calendar. Adding twice adds the events twice.")
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
            .task(id: includeDocuments) {
                tripFileURL = try? TripArchiver.writeFile(for: [trip], includeDocuments: includeDocuments)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addToCalendar() async {
        adding = true
        defer { adding = false }
        do {
            let count = try await CalendarExport.addToCalendar(trip: trip)
            calendarMessage = "Added \(count) \(count == 1 ? "event" : "events") to your calendar."
        } catch {
            calendarMessage = error.localizedDescription
        }
    }
}
