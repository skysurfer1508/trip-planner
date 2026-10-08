import SwiftUI
import SwiftData
import MapKit
import PhotosUI

/// Import a program from a PDF, Word file, photo or text file: read it, find the stops, match them
/// to places, review, add.
struct ImportFlowView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Secrets.self) private var secrets

    private enum Phase {
        case pick
        case working(String)
        case review
        case failed(String)
    }

    @State private var phase: Phase = .pick
    @State private var useAI = true
    @State private var saveCopy = true
    @State private var showFilePicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var draft = ImportDraft()
    @State private var sourceName = ""
    @State private var sourceData: Data?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pick: pickView
                case .working(let message): workingView(message)
                case .review:
                    ItineraryReviewView(trip: trip, draft: draft, notice: notice) {
                        saveSourceCopy()
                        dismiss()
                    }
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Import program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    Task { await process(fileURL: url) }
                case .failure(let error):
                    phase = .failed(error.localizedDescription)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await process(photo: item) }
            }
        }
    }

    // MARK: Phases

    private var pickView: some View {
        Form {
            Section {
                Group {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose a file (PDF, Word, image, text)", systemImage: "doc.badge.plus")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose a photo or screenshot", systemImage: "photo.on.rectangle")
                    }
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("Scanned PDFs and photos are read with on-device text recognition.")
            }

            Section {
                Group {
                    let engine = AIRouter.current(geminiKey: secrets.keys.gemini)
                    Picker("Find stops with", selection: $useAI) {
                        Text("Basic").tag(false)
                        Text(engine?.label ?? "AI (not set up)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useAI && engine == nil {
                        Label("No AI available. Turn on Apple Intelligence, or add a free Gemini key in Settings.",
                              systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text(useAI
                     ? "AI reads almost any layout and language. With Gemini, the document text is sent to Google for this import; Apple Intelligence stays on the phone."
                     : "Free and fully on the phone. Works best with clear day headings, times and one place per line.")
            }

            Section {
                Group {
                    Toggle("Keep a copy in Documents", isOn: $saveCopy)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func workingView(_ message: String) -> some View {
        VStack(spacing: Spacing.l) {
            ProgressView()
            Text(message)
                .foregroundStyle(Theme.inkSecondary)
            if draft.total > 0 {
                ProgressView(value: Double(draft.progress), total: Double(draft.total))
                    .padding(.horizontal, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't import", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { phase = .pick }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Processing

    private func process(fileURL url: URL) async {
        phase = .working("Reading the document…")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            sourceName = url.lastPathComponent
            sourceData = try? Data(contentsOf: url)
            let text = try await DocumentTextExtractor.text(from: url)
            await findStops(in: text)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func process(photo item: PhotosPickerItem) async {
        phase = .working("Reading the image…")
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ExtractError.unreadable
            }
            sourceName = "Program photo.jpg"
            sourceData = data
            let text = try await DocumentTextExtractor.imageText(data: data)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExtractError.empty }
            await findStops(in: text)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        photoItem = nil
    }

    private func findStops(in text: String) async {
        phase = .working("Finding stops…")
        notice = nil

        let range = trip.startDate...max(trip.endDate, trip.startDate)
        var itinerary = ItineraryParser.parse(text, tripRange: range)

        if useAI {
            if let engine = AIRouter.current(geminiKey: secrets.keys.gemini) {
                phase = .working("Reading with \(engine.label)…")
                do {
                    let context = AIContext(destination: trip.destination,
                                            dates: Format.dateRange(trip.startDate, trip.endDate))
                    let aiResult = try await engine.extractItinerary(text: text, context: context)
                    if aiResult.stopCount > 0 {
                        itinerary = aiResult
                        notice = "Read with \(engine.label)."
                    } else {
                        notice = "\(engine.label) found no stops. Used basic reading instead."
                    }
                } catch {
                    notice = "\(error.localizedDescription) Used basic reading instead."
                }
            } else {
                notice = "No AI available. Used basic reading instead."
            }
        }

        guard itinerary.stopCount > 0 else {
            phase = .failed("No stops were found in this document. For free-form text, turn on an AI engine in Settings.")
            return
        }

        draft.load(itinerary, tripDays: trip.sortedDays)
        phase = .working("Looking up places…")
        await draft.resolveAll(center: trip.destinationCoordinate, region: trip.searchRegion)
        phase = .review
    }

    private func saveSourceCopy() {
        guard saveCopy, let data = sourceData else { return }
        let document = TripDocument(title: sourceName, fileName: sourceName, kind: .program, data: data)
        context.insert(document)
        document.trip = trip
    }
}
