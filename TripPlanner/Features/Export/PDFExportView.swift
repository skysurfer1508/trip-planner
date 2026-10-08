import SwiftUI
import QuickLook

/// Make a PDF of the whole itinerary to save, share or print.
struct PDFExportView: View {
    @Bindable var trip: Trip

    @State private var options = PDFOptions()
    @State private var working = false
    @State private var url: URL?
    @State private var preview: URL?
    @State private var failed = false

    var body: some View {
        Form {
            Section("Include") {
                Group {
                    Toggle("Map of each day", isOn: $options.maps)
                    Toggle("Photos of the places", isOn: $options.photos)
                    Toggle("My notes", isOn: $options.notes)
                    Toggle("Flights and hotel", isOn: $options.bookings)
                    Toggle("Emergency numbers and practical info", isOn: $options.practical)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Group {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            Label(url == nil ? "Create PDF" : "Create again", systemImage: "doc.richtext")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working)
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("One A4 page per day (long days continue on a second page), with times, addresses, opening hours and the warnings you see in the app. Maps are drawn from Apple Maps, so a connection helps.")
            }

            if let url {
                Section("Your PDF") {
                    Group {
                        Button {
                            preview = url
                        } label: {
                            Label("Preview", systemImage: "eye")
                        }
                        ShareLink(item: url) {
                            Label("Share or save to Files", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            ItineraryPDF.printPDF(at: url, jobName: trip.name)
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }

            if failed {
                Section {
                    Group {
                        Text("The PDF couldn't be created. Try again.")
                            .foregroundStyle(Theme.danger)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("PDF itinerary")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .onChange(of: options) { url = nil }
    }

    private func create() async {
        working = true
        failed = false
        defer { working = false }
        await TripHolidays.ensure(trip)
        url = await ItineraryPDF.make(trip: trip, options: options)
        failed = url == nil
    }
}
