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

    private struct PickerTarget: Identifiable {
        let id = UUID()
        let dayID: UUID
        let stopID: UUID
        let query: String
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
    @State private var pickerTarget: PickerTarget?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pick: pickView
                case .working(let message): workingView(message)
                case .review: reviewView
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Import program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isReview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(draft.includedCount)") { commit() }
                            .disabled(draft.includedCount == 0)
                    }
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
            .sheet(item: $pickerTarget) { target in
                PlacePickerView(query: target.query, region: trip.searchRegion) { item in
                    apply(item, to: target)
                }
            }
        }
    }

    private var isReview: Bool {
        if case .review = phase { return true }
        return false
    }

    // MARK: Phases

    private var pickView: some View {
        Form {
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose a file (PDF, Word, image, text)", systemImage: "doc.badge.plus")
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose a photo or screenshot", systemImage: "photo.on.rectangle")
                }
            } footer: {
                Text("Scanned PDFs and photos are read with on-device text recognition.")
            }

            Section {
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
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(useAI
                     ? "AI reads almost any layout and language. With Gemini, the document text is sent to Google for this import; Apple Intelligence stays on the phone."
                     : "Free and fully on the phone. Works best with clear day headings, times and one place per line.")
            }

            Section {
                Toggle("Keep a copy in Documents", isOn: $saveCopy)
            }
        }
    }

    private func workingView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
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

    private var reviewView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found \(draft.days.reduce(0) { $0 + $1.stops.count }) possible stops")
                        .font(.headline)
                    Text("Untick anything that isn't a place, fix names, and pick the right day. Stops without a matching place can't be added until you choose one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach($draft.days) { $day in
                Section {
                    ForEach($day.stops) { $stop in
                        DraftStopRow(stop: $stop) {
                            pickerTarget = PickerTarget(dayID: day.id, stopID: stop.id, query: stop.title)
                        }
                    }
                } header: {
                    dayHeader($day)
                }
            }
        }
    }

    private func dayHeader(_ day: Binding<DraftDay>) -> some View {
        HStack {
            Text(day.wrappedValue.label)
                .textCase(nil)
                .font(.subheadline.bold())
            Spacer()
            Picker("Add to", selection: day.targetIndex) {
                ForEach(Array(trip.sortedDays.enumerated()), id: \.offset) { index, tripDay in
                    Text("Day \(index + 1) · \(Format.dayChip(tripDay.date))").tag(index)
                }
            }
            .pickerStyle(.menu)
            .textCase(nil)
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

    private func apply(_ item: MKMapItem, to target: PickerTarget) {
        guard let dayIndex = draft.days.firstIndex(where: { $0.id == target.dayID }),
              let stopIndex = draft.days[dayIndex].stops.firstIndex(where: { $0.id == target.stopID }) else { return }
        draft.days[dayIndex].stops[stopIndex].item = item
        draft.days[dayIndex].stops[stopIndex].include = true
    }

    private func commit() {
        let tripDays = trip.sortedDays
        guard !tripDays.isEmpty else { return }
        let calendar = Calendar.current

        for draftDay in draft.days {
            let day = tripDays[min(max(draftDay.targetIndex, 0), tripDays.count - 1)]
            for draftStop in draftDay.stops where draftStop.include {
                guard let item = draftStop.item else { continue }
                let stop = Stop.from(item)
                if item.pointOfInterestCategory == nil {
                    stop.category = draftStop.category
                }
                if let hour = draftStop.hour {
                    stop.plannedTime = calendar.date(bySettingHour: hour, minute: draftStop.minute ?? 0, second: 0, of: day.date)
                }
                stop.notes = draftStop.notes
                day.append(stop)
            }
        }

        if saveCopy, let data = sourceData {
            let document = TripDocument(title: sourceName, fileName: sourceName, kind: .program, data: data)
            context.insert(document)
            document.trip = trip
        }
        dismiss()
    }
}

private struct DraftStopRow: View {
    @Binding var stop: DraftStop
    let onChangePlace: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Include", isOn: $stop.include)
                .labelsHidden()
                .disabled(stop.item == nil)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: $stop.title)
                    .font(.body)
                if let hour = stop.hour {
                    Text(String(format: "%02d:%02d", hour, stop.minute ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let item = stop.item {
                    Label(item.name.map { "\($0) · \(item.placemark.title ?? "")" } ?? "Matched",
                          systemImage: "mappin.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Label("No match found", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            Button(action: onChangePlace) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
    }
}
