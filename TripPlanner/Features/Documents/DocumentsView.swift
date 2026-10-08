import SwiftUI
import SwiftData
import PhotosUI
import QuickLook

/// Tickets, bookings and ID scans stored with the trip. They live on the device, so they open
/// without internet.
struct DocumentsView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @State private var showFilePicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var previewURL: URL?
    @State private var editing: TripDocument?
    @State private var errorMessage: String?

    private struct KindGroup: Identifiable {
        let kind: DocumentKind
        let docs: [TripDocument]
        var id: String { kind.rawValue }
    }

    private var grouped: [KindGroup] {
        DocumentKind.allCases.compactMap { kind in
            let docs = trip.documents.filter { $0.kind == kind }.sorted { $0.addedAt > $1.addedAt }
            return docs.isEmpty ? nil : KindGroup(kind: kind, docs: docs)
        }
    }

    var body: some View {
        List {
            if trip.documents.isEmpty {
                EmptyState(title: "No documents", systemImage: "folder",
                           message: "Keep tickets, bookings and passport scans here. They're stored on this iPhone and work without internet.")
                    .listRowBackground(Color.clear)
            }

            ForEach(grouped) { group in
                Section {
                    ForEach(group.docs) { doc in
                        Button {
                            preview(doc)
                        } label: {
                            DocumentRow(document: doc)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = doc }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit", systemImage: "pencil") { editing = doc }
                                .tint(Theme.info)
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            context.delete(group.docs[index])
                        }
                    }
                } header: {
                    Text(group.kind.title).eyebrow()
                }
            }

            if let errorMessage {
                Banner(kind: .danger, title: errorMessage)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Choose file", systemImage: "doc.badge.plus") { showFilePicker = true }
                    Button("Choose photo", systemImage: "photo") { showPhotoPicker = true }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add document")
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): add(fileURL: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await add(photo: item) }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $editing) { doc in
            DocumentEditView(document: doc)
        }
    }

    private func add(fileURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            insert(data: data, fileName: url.lastPathComponent)
        } catch {
            errorMessage = "Couldn't read the file: \(error.localizedDescription)"
        }
    }

    private func add(photo item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't read the photo."
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let stamp = Date().formatted(.dateTime.year().month().day().hour().minute())
        insert(data: data, fileName: "Photo \(stamp).\(ext)")
    }

    private func insert(data: Data, fileName: String) {
        errorMessage = nil
        let title = (fileName as NSString).deletingPathExtension
        let doc = TripDocument(title: title, fileName: fileName, kind: .other, data: data)
        context.insert(doc)
        doc.trip = trip
        editing = doc
    }

    private func preview(_ doc: TripDocument) {
        guard let data = doc.data else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = doc.fileName.isEmpty ? "document" : doc.fileName
        let url = folder.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            previewURL = url
        } catch {
            errorMessage = "Couldn't open the document: \(error.localizedDescription)"
        }
    }
}

private struct DocumentRow: View {
    let document: TripDocument

    private var symbol: String {
        switch document.fileExtension {
        case "pdf": "doc.richtext.fill"
        case "png", "jpg", "jpeg", "heic", "heif": "photo.fill"
        case "doc", "docx": "doc.text.fill"
        default: document.kind.symbol
        }
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(document.note.isEmpty ? subtitle : document.note)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(document.data?.count ?? 0), countStyle: .file)
        return "\(document.fileExtension.uppercased()) · \(size)"
    }
}

private struct DocumentEditView: View {
    @Bindable var document: TripDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $document.title)
                    Picker("Type", selection: $document.kind) {
                        ForEach(DocumentKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    TextField("Note (e.g. gate B, seat 14A)", text: $document.note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
