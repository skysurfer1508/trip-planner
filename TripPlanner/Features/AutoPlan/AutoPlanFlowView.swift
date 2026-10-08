import SwiftUI
import SwiftData
import MapKit

/// Auto plan: a short questionnaire, then a complete day-by-day plan built from real places.
struct AutoPlanFlowView: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Secrets.self) private var secrets

    private enum Step: Hashable {
        case approach, who, rhythm, interests, food, nightlife, transport, budget, mustSee, summary
    }

    /// How the plan is made: from suggestions only, around the traveller's places, or from them alone.
    private enum Approach: String, CaseIterable, Identifiable {
        case surprise, around, only
        var id: String { rawValue }

        var title: String {
            switch self {
            case .surprise: "Suggest everything"
            case .around: "Build around my places"
            case .only: "Only my places"
            }
        }

        var detail: String {
            switch self {
            case .surprise: "I pick the best places for you"
            case .around: "Start with places you give me or already added, and fill the rest with suggestions"
            case .only: "Plan the trip with just your places and the stops already in it"
            }
        }

        var symbol: String {
            switch self {
            case .surprise: "sparkles"
            case .around: "mappin.and.ellipse"
            case .only: "list.bullet.clipboard"
            }
        }
    }

    /// What happens to the stops that are already in the trip.
    private enum ExistingMode: String, CaseIterable, Identifiable {
        case keep, replace, add
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keep: "Keep them and plan around them"
            case .replace: "Replace them"
            case .add: "Add the plan next to them"
            }
        }

        var symbol: String {
            switch self {
            case .keep: "pin.fill"
            case .replace: "arrow.triangle.2.circlepath"
            case .add: "plus.circle"
            }
        }
    }

    private enum Phase {
        case questions
        case working(String)
        case review
        case walkthrough
        case failed(String)
    }

    @State private var prefs = TripPreferences()
    @State private var step: Step = .approach
    @State private var approach: Approach = .surprise
    @State private var existingMode: ExistingMode = .add
    @State private var existingStops: [String: Stop] = [:]
    @State private var phase: Phase = .questions
    @State private var mustSees: [MustSee] = []
    @State private var popularSights: [MKMapItem] = []
    @State private var showMustSeeSheet = false
    @State private var draft = ImportDraft()
    @State private var notice: String?
    @State private var plan: [PlannedDay] = []
    @State private var pool: [PlanCandidate] = []
    @State private var leftOut: [PlanCandidate] = []
    @State private var dayWindows: [DayWindow] = []
    @State private var transitMinutes: [String: Int] = [:]

    /// Stops the traveller put in the trip (not the flights and hotel check-ins made from bookings).
    private var ownStopCount: Int {
        trip.days.reduce(0) { $0 + $1.stops.filter { !ExistingStops.isLogistics($0) }.count }
    }

    private var hasExistingStops: Bool { ownStopCount > 0 }

    /// Questions that don't apply are skipped.
    private var steps: [Step] {
        var list: [Step] = [.approach]
        switch approach {
        case .surprise:
            list += [.who, .rhythm, .interests]
            if prefs.interests.contains(.food) { list.append(.food) }
            if prefs.wantsNightlife { list.append(.nightlife) }
            list += [.transport, .budget, .mustSee, .summary]
        case .around:
            list += [.mustSee, .who, .rhythm, .interests]
            if prefs.interests.contains(.food) { list.append(.food) }
            if prefs.wantsNightlife { list.append(.nightlife) }
            list += [.transport, .budget, .summary]
        case .only:
            list += [.mustSee, .rhythm, .transport, .summary]
        }
        return list
    }

    /// Stops of the trip that would be planned around (not flights and hotel check-ins).
    private var keptStopCount: Int {
        ExistingStops.collect(trip: trip, dayCount: prefs.days).candidates.count
    }

    private var stepIndex: Int {
        steps.firstIndex(of: step) ?? 0
    }

    private var canContinue: Bool {
        switch step {
        case .interests: !prefs.interests.isEmpty
        case .mustSee: approach != .only || !mustSees.isEmpty || (existingMode == .keep && keptStopCount > 0)
        default: true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .questions: questions
                case .working(let message): workingView(message)
                case .review:
                    ItineraryReviewView(trip: trip,
                                        draft: draft,
                                        notice: notice,
                                        onBeforeAdd: existingMode == .replace ? clearTargetDays : nil,
                                        onRegenerate: { Task { await create() } },
                                        onWalkThrough: { phase = .walkthrough }) {
                        dismiss()
                    }
                case .walkthrough:
                    PlanWalkthroughView(trip: trip,
                                        plan: $plan,
                                        pool: $pool,
                                        leftOut: $leftOut,
                                        prefs: prefs,
                                        windows: dayWindows,
                                        transitMinutes: transitMinutes) {
                        rebuildDraft()
                        notice = "Adjusted in the walk-through."
                        phase = .review
                    }
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Auto plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Questions

    private var questions: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(stepIndex + 1), total: Double(steps.count))
                .padding(.horizontal)
                .padding(.top, Spacing.s)

            page
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.snappy, value: step)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Spacing.m) {
                if stepIndex > 0 {
                    Button("Back") { go(-1) }
                        .buttonStyle(.bordered)
                }
                Button {
                    if step == .summary {
                        Task { await create() }
                    } else {
                        go(1)
                    }
                } label: {
                    Text(step == .summary ? "Create my plan" : "Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .approach: approachPage
        case .who: whoPage
        case .rhythm: rhythmPage
        case .interests: interestsPage
        case .food: foodPage
        case .nightlife: nightlifePage
        case .transport: transportPage
        case .budget: budgetPage
        case .mustSee: mustSeePage
        case .summary: summaryPage
        }
    }

    private var approachPage: some View {
        QuestionPage(title: "How do you want to plan?", subtitle: "You can change anything afterwards, day by day.") {
            ForEach(Approach.allCases) { option in
                OptionCard(title: option.title, detail: option.detail, symbol: option.symbol,
                           isSelected: approach == option) {
                    approach = option
                }
            }
            if hasExistingStops {
                Label("This trip already has \(ownStopCount) \(ownStopCount == 1 ? "stop" : "stops"). You choose what happens to them on the last page.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var whoPage: some View {
        QuestionPage(title: "Who's going?", subtitle: "This shapes the pace, the evenings and the kind of places.") {
            ForEach(TripPreferences.Group.allCases) { group in
                OptionCard(title: group.title, detail: group.detail, symbol: group.symbol,
                           isSelected: prefs.group == group) {
                    prefs.group = group
                    prefs.travelers = group.defaultTravelers
                }
            }
            Stepper("People: \(prefs.travelers)", value: $prefs.travelers, in: 1...30)
                .padding(.top, Spacing.xs)
        }
    }

    private var rhythmPage: some View {
        QuestionPage(title: "How do you like your days?") {
            Stepper("Days: \(prefs.days)", value: $prefs.days, in: 1...max(1, min(trip.days.count, 14)))
            if trip.days.count > 0 {
                Text("Your trip has \(trip.days.count) \(trip.days.count == 1 ? "day" : "days"). Change the trip dates to plan more.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }

            if approach != .only {
                Text("Pace").font(.headline).padding(.top, Spacing.s)
                ForEach(TripPreferences.Pace.allCases) { pace in
                    OptionCard(title: pace.title, detail: pace.detail, symbol: pace.symbol,
                               isSelected: prefs.pace == pace) {
                        prefs.pace = pace
                    }
                }
            }

            Text("Start the day").font(.headline).padding(.top, Spacing.s)
            Picker("Start", selection: $prefs.dayStart) {
                ForEach(TripPreferences.DayStart.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var interestsPage: some View {
        QuestionPage(title: "What do you like?", subtitle: "Pick everything that sounds good.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(TripPreferences.Interest.allCases) { interest in
                    SelectTile(title: interest.title, symbol: interest.symbol, isOn: prefs.interests.contains(interest)) {
                        if prefs.interests.contains(interest) {
                            prefs.interests.remove(interest)
                        } else {
                            prefs.interests.insert(interest)
                        }
                    }
                }
            }
            if prefs.interests.isEmpty {
                Label("Pick at least one.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
            if !prefs.interests.contains(.nightlife) && approach != .only {
                Label("No nightlife: the days end after dinner.", systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if prefs.isFamily && prefs.interests.contains(.nightlife) {
                Label("Nightlife is skipped on family trips.", systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var foodPage: some View {
        QuestionPage(title: "Food", subtitle: "What should the plan include?") {
            Toggle("Plan lunch", isOn: $prefs.includeLunch)
            Toggle("Plan dinner", isOn: $prefs.includeDinner)
            Toggle("Vegetarian", isOn: $prefs.vegetarian)

            Text("Favourite cuisines").font(.headline).padding(.top, Spacing.s)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: Spacing.s)], alignment: .leading, spacing: Spacing.s) {
                ForEach(Cuisine.allCases) { cuisine in
                    SelectableChip(title: cuisine.title, isOn: prefs.cuisines.contains(cuisine.rawValue)) {
                        if prefs.cuisines.contains(cuisine.rawValue) {
                            prefs.cuisines.remove(cuisine.rawValue)
                        } else {
                            prefs.cuisines.insert(cuisine.rawValue)
                        }
                    }
                }
            }
            Text("Nothing picked means a mix of the best-rated places.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var nightlifePage: some View {
        QuestionPage(title: "Nightlife", subtitle: "What kind of evening do you want?") {
            OptionCard(title: "No nightlife", detail: "Dinner, then the day is done", symbol: "moon.zzz.fill",
                       isSelected: false) {
                skipNightlife()
            }
            ForEach(TripPreferences.NightlifeStyle.allCases) { style in
                OptionCard(title: style.title, symbol: style.symbol, isSelected: prefs.nightlifeStyle == style) {
                    prefs.nightlifeStyle = style
                }
            }
            Picker("Out until", selection: $prefs.nightEndHour) {
                Text("22:00").tag(22)
                Text("23:00").tag(23)
                Text("Midnight").tag(24)
            }
            .pickerStyle(.segmented)
            .padding(.top, Spacing.xs)
        }
    }

    private var transportPage: some View {
        QuestionPage(title: "Getting around", subtitle: "It decides how spread out each day can be.") {
            ForEach(TripPreferences.Transport.allCases) { transport in
                OptionCard(title: transport.title, detail: transport.detail, symbol: transport.symbol,
                           isSelected: prefs.transport == transport) {
                    prefs.transport = transport
                }
            }
        }
    }

    private var budgetPage: some View {
        QuestionPage(title: "Budget", subtitle: "Used to pick restaurants where price information is available.") {
            ForEach(TripPreferences.Budget.allCases) { budget in
                OptionCard(title: budget.title, detail: budget.detail, symbol: budget.symbol,
                           isSelected: prefs.budget == budget) {
                    prefs.budget = budget
                }
            }
        }
    }

    private var mustSeePage: some View {
        QuestionPage(title: approach == .surprise ? "Anything you must see?" : "Your places",
                     subtitle: approach == .surprise
                        ? "Optional. These always make it into the plan. Say when you want to be there and the plan is built around it."
                        : "Add the places you want, one by one or as a pasted list. Say when you want to be somewhere and the plan is built around it.") {
            if hasExistingStops && existingMode == .keep {
                Label("\(keptStopCount) \(keptStopCount == 1 ? "stop" : "stops") already in this trip \(keptStopCount == 1 ? "is" : "are") included.",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
            }
            ForEach(mustSees) { entry in
                HStack(spacing: Spacing.m) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.subheadline.weight(.medium))
                        if let when = entry.whenText {
                            Label(when, systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        if let address = entry.item.readableAddress {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        mustSees.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .accessibilityLabel("Remove \(entry.name)")
                }
                .padding(Spacing.m)
                .background(Theme.surface, in: Radius.shape(Radius.small))
            }
            Button {
                showMustSeeSheet = true
            } label: {
                Label(mustSees.isEmpty ? "Add something you want to see" : "Add another",
                      systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .sheet(isPresented: $showMustSeeSheet) {
                MustSeeSheet(destinationName: trip.destination,
                             center: trip.destinationCoordinate,
                             region: trip.searchRegion,
                             dayCount: prefs.days,
                             popular: popularSights.filter { sight in
                                 !mustSees.contains { $0.name == sight.name }
                             }) { entry in
                    mustSees.append(entry)
                }
            }
        }
        .task { await loadPopularSights() }
    }

    private var summaryPage: some View {
        QuestionPage(title: "Ready?", subtitle: "Here's what I'll plan.") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                summaryRow(approach.symbol, approach.title)
                summaryRow("person.2.fill", groupSummary)
                summaryRow("calendar", daysSummary)
                if approach != .only {
                    summaryRow("heart.fill", prefs.interests.map(\.title).sorted().joined(separator: ", "))
                }
                if approach != .only && prefs.interests.contains(.food) {
                    summaryRow("fork.knife", foodSummary)
                }
                if approach != .only && prefs.wantsNightlife {
                    summaryRow("moon.stars.fill", nightlifeSummary)
                }
                summaryRow(prefs.transport.symbol, prefs.transport.title)
                if approach != .only {
                    summaryRow(prefs.budget.symbol, prefs.budget.title)
                }
                if !mustSees.isEmpty {
                    summaryRow("mappin.and.ellipse", mustSeeSummary)
                }
            }
            .card()

            if hasExistingStops {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Stops already in this trip").font(.headline)
                    ForEach(ExistingMode.allCases) { mode in
                        OptionCard(title: mode.title, symbol: mode.symbol, isSelected: existingMode == mode) {
                            existingMode = mode
                        }
                    }
                    Text(existingFooter)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    // The summary lines are built here, in small typed steps, so the compiler has little to work out.

    private var groupSummary: String {
        let people: String = prefs.travelers == 1 ? "person" : "people"
        return "\(prefs.group.title), \(prefs.travelers) \(people)"
    }

    private var daysSummary: String {
        let days: String = prefs.days == 1 ? "day" : "days"
        let pace = prefs.pace.title.lowercased()
        let start = prefs.dayStart.title.lowercased()
        return "\(prefs.days) \(days), \(pace) pace, starting \(start)"
    }

    private var foodSummary: String {
        var parts: [String] = []
        if prefs.includeLunch { parts.append("Lunch") }
        if prefs.includeDinner { parts.append("Dinner") }
        if prefs.vegetarian { parts.append("Vegetarian") }
        return parts.joined(separator: ", ")
    }

    private var nightlifeSummary: String {
        let until: String = prefs.nightEndHour == 24 ? "midnight" : "\(prefs.nightEndHour):00"
        return "\(prefs.nightlifeStyle.title) until \(until)"
    }

    private var mustSeeSummary: String {
        var names: [String] = []
        for entry in mustSees {
            if let when = entry.whenText {
                names.append("\(entry.name) (\(when.lowercased()))")
            } else {
                names.append(entry.name)
            }
        }
        return names.joined(separator: ", ")
    }

    private var existingFooter: String {
        switch existingMode {
        case .keep: "Your stops stay, with their notes and photos, and the plan fits around their day and time. Stops you untick or that don't fit stay where they are. Flights and hotel check-ins are never touched."
        case .replace: "Stops on the days the plan fills are removed when you add the new plan. Flights and hotel check-ins stay."
        case .add: "The new plan is added to what you already have."
        }
    }

    private func summaryRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: Other phases

    private func workingView(_ message: String) -> some View {
        VStack(spacing: Spacing.l) {
            ProgressView()
            Text(message)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't build a plan", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back to the questions") { phase = .questions }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func load() {
        if let data = trip.planPreferences,
           let saved = try? JSONDecoder().decode(TripPreferences.self, from: data) {
            prefs = saved
        } else {
            prefs.transport = trip.transport
        }
        prefs.days = min(max(trip.days.count, 1), 14)
        existingMode = hasExistingStops ? .keep : .add
    }

    /// "No nightlife": takes it out of the interests and moves on to the next question.
    private func skipNightlife() {
        let next = steps.indices.contains(stepIndex + 1) ? steps[stepIndex + 1] : Step.transport
        prefs.interests.remove(.nightlife)
        step = next
    }

    /// The destination's best-known sights, offered as one-tap must-sees.
    private func loadPopularSights() async {
        guard popularSights.isEmpty, let center = trip.destinationCoordinate ?? trip.anyCoordinate else { return }
        let result = await SuggestionService.load(kind: .sights, center: center, radiusMeters: 12_000, keys: secrets.keys)
        popularSights = result.places
            .sorted { $0.score > $1.score }
            .prefix(12)
            .map { place in
                let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                item.name = place.name
                return item
            }
    }

    private func go(_ offset: Int) {
        let target = min(max(stepIndex + offset, 0), steps.count - 1)
        step = steps[target]
    }

    private func create() async {
        guard let center = trip.destinationCoordinate ?? trip.anyCoordinate else {
            phase = .failed("Set the trip's destination first (Overview → Get ready).")
            return
        }
        if let data = try? JSONEncoder().encode(prefs) {
            trip.planPreferences = data
        }
        trip.transport = prefs.transport

        phase = .working("Finding the best places…")
        // Flights and hotel: when each day can start and has to end, and where it starts from.
        let tripDays = trip.sortedDays
        let windows = (0..<prefs.days).map { index in
            tripDays.indices.contains(index) ? trip.window(for: tripDays[index].date) : DayWindow()
        }
        var logisticsNotes: [String] = []
        for (index, window) in windows.enumerated() {
            if let start = window.startMinute {
                logisticsNotes.append("Day \(index + 1) starts at \(TripLogistics.timeText(start)), after you land.")
            }
            if let end = window.endMinute {
                logisticsNotes.append("Day \(index + 1) ends by \(TripLogistics.timeText(end)) for your flight.")
            }
        }

        let collected = existingMode == .keep
            ? ExistingStops.collect(trip: trip, dayCount: prefs.days)
            : ExistingStops.Collected()
        existingStops = collected.stops

        let output = await AutoPlanService.build(prefs: prefs,
                                                 center: center,
                                                 mustSees: mustSees,
                                                 fixed: collected.candidates,
                                                 fillGaps: approach != .only,
                                                 keys: secrets.keys,
                                                 windows: windows)
        guard output.days.contains(where: { !$0.stops.isEmpty }) else {
            phase = .failed("Not enough places were found around \(trip.destination.isEmpty ? "the destination" : trip.destination). Check your connection, or choose a wider way of getting around.")
            return
        }

        phase = .working("Planning your days…")
        var themes = output.days.map(\.theme)
        if let engine = AIRouter.current(geminiKey: secrets.keys.gemini) {
            let input = output.days.enumerated().map { index, day in
                DayThemeInput(day: index + 1, stops: day.stops.map { $0.candidate.name })
            }
            if let titles = try? await engine.dayThemes(input, destination: trip.destination),
               titles.count == output.days.count {
                themes = titles
            }
        }

        plan = output.days
        for index in plan.indices where themes.indices.contains(index) {
            plan[index].theme = themes[index]
        }
        pool = output.candidates
        leftOut = output.leftOut
        dayWindows = windows
        transitMinutes = [:]
        if prefs.transport == .transit && TransitRouter.isEnabled {
            phase = .working("Checking public transport…")
            let zone = await TripTimeZone.ensure(trip)
            let refined = await TransitRefiner.refine(plan, prefs: prefs, windows: windows,
                                                      dates: tripDays.map(\.date), zone: zone)
            plan = refined.days
            transitMinutes = refined.minutes
            if !refined.minutes.isEmpty {
                logisticsNotes.append("Travel times use real public transport timetables where available.")
            }
        }
        rebuildDraft()
        let notes = logisticsNotes + output.notices
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
        phase = .review
    }

    /// The review list always mirrors `plan`, so changes from the walk-through show up there.
    private func rebuildDraft() {
        draft = ImportDraft()
        draft.load(plan: plan, themes: plan.map(\.theme), tripDays: trip.sortedDays, existing: existingStops)
    }

    /// "Replace": removes the stops of the days the new plan is about to fill. (In "keep" mode only the
    /// stops that were copied into the plan are replaced, by the review screen itself.)
    private func clearTargetDays() {
        let days = trip.sortedDays
        for index in Set(draft.days.map(\.targetIndex)) where days.indices.contains(index) {
            // Flights and hotel check-ins come from the bookings and stay.
            for stop in Array(days[index].stops) where !ExistingStops.isLogistics(stop) {
                days[index].remove(stop)
            }
        }
    }
}
