import SwiftUI
import PhotosUI

/// One stop: photo, what it is, opening hours for the week, contact details, and the settings for the
/// visit (time, stay, cost, notes). Directions and Done stay in a bar at the bottom.
struct StopDetailView: View {
    @Bindable var stop: Stop
    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    photoHeader

                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        titleBlock
                        aboutBlock
                        hoursBlock
                        contactBlock
                        scheduleCard
                        budgetCard
                        tipsCard
                        notesCard
                        photoActions
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.xl)
                }
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
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

    // MARK: Header

    /// The photo scrolls a little slower than the page and stretches when pulled down. Still with
    /// Reduce Motion.
    private var photoHeader: some View {
        ZStack {
            StopPhoto(stop: stop, height: 260)
            if loadingInfo && stop.imageData == nil {
                SkeletonView(height: 260, radius: 0)
            }
        }
        .visualEffect { [reduce = reduceMotion] content, proxy in
            let minY = proxy.frame(in: .scrollView).minY
            return content
                .offset(y: reduce ? 0 : (minY > 0 ? -minY : -minY * 0.5))
                .scaleEffect(reduce || minY <= 0 ? 1 : 1 + minY / 500, anchor: .bottom)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField("Name", text: $stop.name, axis: .vertical)
                .font(Typography.display)
                .foregroundStyle(Theme.ink)
            Picker("Category", selection: $stop.category) {
                ForEach(StopCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.category(stop.category))
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    @ViewBuilder
    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !stop.summary.isEmpty {
                Text(stop.summary)
                    .font(Typography.body)
                    .foregroundStyle(Theme.ink)
                if let url = URL(string: stop.wikiURL), !stop.wikiURL.isEmpty {
                    Link("Read more on Wikipedia", destination: url)
                        .font(Typography.label)
                        .frame(minHeight: 44, alignment: .leading)
                }
                if stop.imageSource != "user" {
                    Text("Text and photo from Wikipedia (CC BY-SA)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            } else if loadingInfo {
                SkeletonView(height: 14)
                SkeletonView(height: 14)
                SkeletonView(height: 14, width: 160)
            } else {
                Text("No description found for this place.")
                    .font(Typography.label)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    // MARK: Opening hours

    @ViewBuilder
    private var hoursBlock: some View {
        if OpeningHoursLoader.shouldLookUp(stop) {
            let trip = stop.day?.trip
            let isHoliday: (Date) -> Bool = { trip?.isNationalHoliday($0) ?? false }
            let date = stop.plannedTime ?? stop.day?.date ?? Date()

            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader(title: "Opening hours")

                if stop.openingHours.isEmpty {
                    if stop.hoursCheckedAt == nil {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            SkeletonView(height: 64)
                            Text("Looking up opening hours…")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    } else {
                        Text("No opening hours are listed for this place on OpenStreetMap. Check the website or ask on the spot.")
                            .font(Typography.label)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } else if let hours = OpeningHours.parse(stop.openingHours) {
                    if let planned = stop.plannedTime,
                       let warning = OpeningHours.warning(for: hours.verdict(visitAt: planned, minutes: stop.durationMinutes,
                                                                            isHoliday: isHoliday)) {
                        Banner(kind: .warning, title: warning)
                    }
                    weekStrip(hours.week(around: date, isHoliday: isHoliday), highlighted: visitWeekdayIndex(date),
                              visitLabel: Calendar.current.isDateInToday(date) ? "Today" : "Your visit")
                    Text("Seasons and public holidays are applied for the week of \(date.formatted(date: .abbreviated, time: .omitted)).")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    hoursSourceNote
                } else {
                    Text(stop.openingHours)
                        .font(Typography.body)
                        .foregroundStyle(Theme.ink)
                    Text("These hours use a format the app can't check automatically.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }

                if !stop.openingHours.isEmpty || stop.hoursCheckedAt != nil {
                    Button {
                        Task { await OpeningHoursLoader.ensureHours(for: stop, force: true) }
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary(fullWidth: false))
                    Text("Source: OpenStreetMap contributors (ODbL). Hours can be out of date; confirm before a long trip.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    /// Monday = 0 ... Sunday = 6, matching `OpeningHours.week`.
    private func visitWeekdayIndex(_ date: Date) -> Int {
        (Calendar.current.component(.weekday, from: date) + 5) % 7
    }

    /// Seven day cells, Monday first. The day of the visit has a border, a fill and a label.
    private func weekStrip(_ week: [(day: String, text: String)], highlighted: Int, visitLabel: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(Array(week.enumerated()), id: \.offset) { index, entry in
                    let isVisit = index == highlighted
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(isVisit ? visitLabel : String(entry.day.prefix(3)))
                            .font(Typography.eyebrow)
                            .textCase(.uppercase)
                            .foregroundStyle(isVisit ? Theme.accent : Theme.inkSecondary)
                        if isVisit {
                            Text(String(entry.day.prefix(3)))
                                .font(Typography.label)
                                .foregroundStyle(Theme.ink)
                        }
                        Text(entry.text)
                            .font(Typography.label)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(width: 104, alignment: .topLeading)
                    .frame(minHeight: 76, alignment: .topLeading)
                    .padding(Spacing.m)
                    .background(isVisit ? Theme.accent.opacity(0.12) : Theme.surface, in: Radius.shape(Radius.small))
                    .overlay(Radius.shape(Radius.small)
                        .strokeBorder(isVisit ? Theme.accent : Theme.separator, lineWidth: isVisit ? 2 : 0.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.day): \(entry.text)\(isVisit ? ", \(visitLabel.lowercased())" : "")")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    /// Which OpenStreetMap object the hours come from, with a way out when it is the wrong one.
    @ViewBuilder
    private var hoursSourceNote: some View {
        if !stop.hoursSource.isEmpty {
            Label("From the OpenStreetMap entry “\(stop.hoursSource)”", systemImage: "info.circle")
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        Button(role: .destructive) {
            stop.rejectedHours = stop.openingHours
            stop.openingHours = ""
            stop.hoursSource = ""
            stop.hoursCheckedAt = Date()
        } label: {
            Label("These hours are wrong", systemImage: "hand.thumbsdown")
                .font(Typography.label)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    // MARK: Contact

    @ViewBuilder
    private var contactBlock: some View {
        let phoneURL = stop.phone.isEmpty ? nil : URL(string: "tel:" + stop.phone.filter { $0.isNumber || $0 == "+" })
        let siteURL = stop.website.isEmpty ? nil : URL(string: stop.website)

        if !stop.address.isEmpty || phoneURL != nil || siteURL != nil {
            VStack(alignment: .leading, spacing: 0) {
                if !stop.address.isEmpty {
                    InfoRow(symbol: "mappin.and.ellipse", title: stop.address)
                }
                if let phoneURL {
                    Link(destination: phoneURL) {
                        InfoRow(symbol: "phone.fill", title: stop.phone)
                    }
                }
                if let siteURL {
                    Link(destination: siteURL) {
                        InfoRow(symbol: "safari", title: "Website")
                    }
                }
            }
            .card(padding: Spacing.m)
        }
    }

    // MARK: Visit settings

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Schedule")
            Card {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Toggle("Planned time", isOn: hasTime)
                    if stop.plannedTime != nil {
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    }
                    Stepper("Stay: \(Format.minutes(stop.durationMinutes))",
                            value: $stop.durationMinutes, in: 15...600, step: 15)
                }
                .font(Typography.body)
                .tint(Theme.accent)
            }
        }
    }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Budget")
            Card {
                HStack(spacing: Spacing.s) {
                    Text("Estimated cost")
                        .font(Typography.body)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Spacing.s)
                    TextField("0", value: $stop.estimatedCost, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120, minHeight: 44)
                    Text(stop.day?.trip?.currencyCode ?? "")
                        .font(Typography.label)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var tipsCard: some View {
        if !stop.aiTips.isEmpty || AIRouter.current(geminiKey: secrets.keys.gemini) != nil {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader(title: "Tips")
                Card {
                    AITipsSection(name: stop.name,
                                  city: stop.day?.trip?.destination ?? "",
                                  cached: $stop.aiTips)
                }
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Notes")
            Card {
                TextField("Tickets, tips, reservation number…", text: $stop.notes, axis: .vertical)
                    .font(Typography.body)
                    .lineLimit(3...8)
            }
        }
    }

    // MARK: Photo actions

    private var photoActions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(stop.imageData == nil ? "Add my own photo" : "Use my own photo instead",
                      systemImage: "photo.badge.plus")
            }
            .buttonStyle(.secondary)
            if stop.imageData != nil {
                Button(role: .destructive) {
                    Haptics.warning()
                    stop.imageData = nil
                    stop.imageSource = ""
                } label: {
                    Label("Remove photo", systemImage: "trash")
                        .font(Typography.label)
                }
                .frame(minHeight: 44)
            }
            Button {
                Task {
                    loadingInfo = true
                    await PlaceInfoLoader.ensureInfo(for: stop, force: true)
                    loadingInfo = false
                }
            } label: {
                Label("Look up photo and description again", systemImage: "arrow.clockwise")
                    .font(Typography.label)
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: Sticky bar

    private var actionBar: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.s))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        return layout {
            Button {
                RoutingService.openInMaps(name: stop.name, coordinate: stop.coordinate, mode: .walk)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(.primary)

            Button {
                Motion.perform(Motion.snappy) { stop.isDone.toggle() }
                if stop.isDone { Haptics.success() }
            } label: {
                Label(stop.isDone ? "Done" : "Mark done",
                      systemImage: stop.isDone ? "checkmark.circle.fill" : "checkmark.circle")
                    .symbolEffect(.bounce, value: stop.isDone)
            }
            .buttonStyle(.secondary)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(.bar)
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
