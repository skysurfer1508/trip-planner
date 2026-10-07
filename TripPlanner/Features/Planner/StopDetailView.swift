import SwiftUI
import PhotosUI

struct StopDetailView: View {
    @Bindable var stop: Stop
    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingInfo = false

    private static let defaultHour = 9

    private var hasTime: Binding<Bool> {
        Binding(
            get: { stop.plannedTime != nil },
            set: { on in
                if on {
                    let base = stop.day?.date ?? Date()
                    stop.plannedTime = Calendar.current.date(bySettingHour: Self.defaultHour, minute: 0, second: 0, of: base)
                } else {
                    stop.plannedTime = nil
                }
            }
        )
    }

    private var time: Binding<Date> {
        Binding(
            get: { stop.plannedTime ?? Date() },
            set: { newValue in
                stop.plannedTime = stop.day?.combine(time: newValue) ?? newValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection

                hoursSection

                Section {
                    TextField("Name", text: $stop.name)
                    Picker("Category", selection: $stop.category) {
                        ForEach(StopCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(category)
                        }
                    }
                    if !stop.address.isEmpty {
                        Label(stop.address, systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !stop.phone.isEmpty,
                       let url = URL(string: "tel:" + stop.phone.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) {
                            Label(stop.phone, systemImage: "phone.fill")
                        }
                    }
                    if !stop.website.isEmpty, let url = URL(string: stop.website) {
                        Link(destination: url) {
                            Label("Website", systemImage: "safari")
                        }
                    }
                }

                Section("Schedule") {
                    Toggle("Planned time", isOn: hasTime)
                    if stop.plannedTime != nil {
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    }
                    Stepper("Stay: \(Format.minutes(stop.durationMinutes))",
                            value: $stop.durationMinutes, in: 15...600, step: 15)
                    Toggle("Done", isOn: $stop.isDone)
                }

                Section("Budget") {
                    HStack {
                        Text("Estimated cost")
                        Spacer()
                        TextField("0", value: $stop.estimatedCost, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                        Text(stop.day?.trip?.currencyCode ?? "")
                            .foregroundStyle(.secondary)
                    }
                }

                if !stop.aiTips.isEmpty || AIRouter.current(geminiKey: secrets.keys.gemini) != nil {
                    Section("Tips") {
                        AITipsSection(name: stop.name,
                                      city: stop.day?.trip?.destination ?? "",
                                      cached: $stop.aiTips)
                    }
                }

                Section("Notes") {
                    TextField("Tickets, tips, reservation number…", text: $stop.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Button("Directions in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        RoutingService.openInMaps(name: stop.name, coordinate: stop.coordinate, mode: .walk)
                    }
                }
            }
            .navigationTitle("Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                loadingInfo = stop.infoCheckedAt == nil
                await PlaceInfoLoader.ensureInfo(for: stop)
                loadingInfo = false
                await OpeningHoursLoader.ensureHours(for: stop)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let prepared = Self.prepared(data) {
                        stop.imageData = prepared
                        stop.imageSource = "user"
                    }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Opening hours

    @ViewBuilder
    private var hoursSection: some View {
        if OpeningHoursLoader.shouldLookUp(stop) {
            let trip = stop.day?.trip
            let isHoliday: (Date) -> Bool = { trip?.isNationalHoliday($0) ?? false }
            let date = stop.plannedTime ?? stop.day?.date ?? Date()

            Section("Opening hours") {
                if stop.openingHours.isEmpty {
                    if stop.hoursCheckedAt == nil {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking up opening hours…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No opening hours are listed for this place on OpenStreetMap. Check the website or ask on the spot.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let hours = OpeningHours.parse(stop.openingHours) {
                    if let planned = stop.plannedTime,
                       let warning = OpeningHours.warning(for: hours.verdict(visitAt: planned, minutes: stop.durationMinutes,
                                                                            isHoliday: isHoliday)) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(hours.week(around: date, isHoliday: isHoliday).enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.day)
                            Spacer()
                            Text(entry.text)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    Text("Seasons and public holidays are applied for the week of \(date.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(stop.openingHours)
                        .font(.subheadline)
                    Text("These hours use a format the app can't check automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !stop.openingHours.isEmpty || stop.hoursCheckedAt != nil {
                    Button("Check again", systemImage: "arrow.clockwise") {
                        Task { await OpeningHoursLoader.ensureHours(for: stop, force: true) }
                    }
                    Text("Source: OpenStreetMap contributors (ODbL). Hours can be out of date; confirm before a long trip.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Photo and description

    @ViewBuilder
    private var photoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if let data = stop.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if loadingInfo {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for a photo…")
                            .foregroundStyle(.secondary)
                    }
                }

                if !stop.summary.isEmpty {
                    Text(stop.summary)
                        .font(.subheadline)
                    if let url = URL(string: stop.wikiURL), !stop.wikiURL.isEmpty {
                        Link("Read more on Wikipedia", destination: url)
                            .font(.footnote)
                    }
                    if stop.imageSource != "user" {
                        Text("Text and photo from Wikipedia (CC BY-SA)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if !loadingInfo {
                    Text("No description found for this place.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(stop.imageData == nil ? "Add my own photo" : "Use my own photo instead",
                      systemImage: "photo.badge.plus")
            }
            if stop.imageData != nil {
                Button("Remove photo", systemImage: "trash", role: .destructive) {
                    stop.imageData = nil
                    stop.imageSource = ""
                }
            }
            Button("Look up photo and description again", systemImage: "arrow.clockwise") {
                Task {
                    loadingInfo = true
                    await PlaceInfoLoader.ensureInfo(for: stop, force: true)
                    loadingInfo = false
                }
            }
        }
    }

    /// Photos from the library are shrunk so a trip stays small.
    private static func prepared(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1024 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
