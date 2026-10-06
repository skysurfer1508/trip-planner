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
        case who, rhythm, interests, food, nightlife, transport, budget, mustSee, summary
    }

    private enum Phase {
        case questions
        case working(String)
        case review
        case failed(String)
    }

    @State private var prefs = TripPreferences()
    @State private var step: Step = .who
    @State private var phase: Phase = .questions
    @State private var mustSees: [MKMapItem] = []
    @State private var showMustSeePicker = false
    @State private var replaceExisting = false
    @State private var draft = ImportDraft()
    @State private var notice: String?

    private var hasExistingStops: Bool {
        trip.days.contains { !$0.stops.isEmpty }
    }

    /// Questions that don't apply are skipped.
    private var steps: [Step] {
        var list: [Step] = [.who, .rhythm, .interests]
        if prefs.interests.contains(.food) { list.append(.food) }
        if prefs.wantsNightlife { list.append(.nightlife) }
        list += [.transport, .budget, .mustSee, .summary]
        return list
    }

    private var stepIndex: Int {
        steps.firstIndex(of: step) ?? 0
    }

    private var canContinue: Bool {
        step != .interests || !prefs.interests.isEmpty
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
                                        onBeforeAdd: replaceExisting ? clearTargetDays : nil,
                                        onRegenerate: { Task { await create() } }) {
                        dismiss()
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
                .padding(.top, 8)

            page
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.snappy, value: step)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
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
                .padding(.top, 4)
        }
    }

    private var rhythmPage: some View {
        QuestionPage(title: "How do you like your days?") {
            Stepper("Days: \(prefs.days)", value: $prefs.days, in: 1...max(1, min(trip.days.count, 14)))
            if trip.days.count > 0 {
                Text("Your trip has \(trip.days.count) \(trip.days.count == 1 ? "day" : "days"). Change the trip dates to plan more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Pace").font(.headline).padding(.top, 6)
            ForEach(TripPreferences.Pace.allCases) { pace in
                OptionCard(title: pace.title, detail: pace.detail, symbol: pace.symbol,
                           isSelected: prefs.pace == pace) {
                    prefs.pace = pace
                }
            }

            Text("Start the day").font(.headline).padding(.top, 6)
            Picker("Start", selection: $prefs.dayStart) {
                ForEach(TripPreferences.DayStart.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var interestsPage: some View {
        QuestionPage(title: "What do you like?", subtitle: "Pick everything that sounds good.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
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
                    .foregroundStyle(.orange)
            }
            if prefs.isFamily && prefs.interests.contains(.nightlife) {
                Label("Nightlife is skipped on family trips.", systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var foodPage: some View {
        QuestionPage(title: "Food", subtitle: "What should the plan include?") {
            Toggle("Plan lunch", isOn: $prefs.includeLunch)
            Toggle("Plan dinner", isOn: $prefs.includeDinner)
            Toggle("Vegetarian", isOn: $prefs.vegetarian)

            Text("Favourite cuisines").font(.headline).padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Cuisine.allCases) { cuisine in
                    FilterChip(title: cuisine.title, isOn: prefs.cuisines.contains(cuisine.rawValue)) {
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
                .foregroundStyle(.secondary)
        }
    }

    private var nightlifePage: some View {
        QuestionPage(title: "Nightlife", subtitle: "What kind of evening do you want?") {
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
            .padding(.top, 4)
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
        QuestionPage(title: "Anything you must see?", subtitle: "Optional. These always make it into the plan.") {
            ForEach(Array(mustSees.enumerated()), id: \.offset) { index, item in
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(item.name ?? "Place")
                        if let address = item.placemark.title {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        mustSees.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove \(item.name ?? "place")")
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                showMustSeePicker = true
            } label: {
                Label("Add a place", systemImage: "plus.circle.fill")
            }
            .sheet(isPresented: $showMustSeePicker) {
                PlacePickerView(query: "", region: trip.searchRegion) { item in
                    mustSees.append(item)
                }
            }
        }
    }

    private var summaryPage: some View {
        QuestionPage(title: "Ready?", subtitle: "Here's what I'll plan.") {
            VStack(alignment: .leading, spacing: 10) {
                summaryRow("person.2.fill", "\(prefs.group.title), \(prefs.travelers) \(prefs.travelers == 1 ? "person" : "people")")
                summaryRow("calendar", "\(prefs.days) \(prefs.days == 1 ? "day" : "days"), \(prefs.pace.title.lowercased()) pace, starting \(prefs.dayStart.title.lowercased())")
                summaryRow("heart.fill", prefs.interests.map(\.title).sorted().joined(separator: ", "))
                if prefs.interests.contains(.food) {
                    summaryRow("fork.knife", [prefs.includeLunch ? "Lunch" : nil, prefs.includeDinner ? "Dinner" : nil,
                                              prefs.vegetarian ? "Vegetarian" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                }
                if prefs.wantsNightlife {
                    summaryRow("moon.stars.fill", "\(prefs.nightlifeStyle.title) until \(prefs.nightEndHour == 24 ? "midnight" : "\(prefs.nightEndHour):00")")
                }
                summaryRow(prefs.transport.symbol, prefs.transport.title)
                summaryRow(prefs.budget.symbol, prefs.budget.title)
                if !mustSees.isEmpty {
                    summaryRow("mappin.and.ellipse", mustSees.compactMap(\.name).joined(separator: ", "))
                }
            }
            .card()

            if hasExistingStops {
                Toggle("Replace the stops already in this trip", isOn: $replaceExisting)
                Text(replaceExisting
                     ? "Stops on the days the plan fills will be removed when you add the new plan."
                     : "The new plan is added to what you already have.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: Other phases

    private func workingView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
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
        }
        prefs.days = min(max(trip.days.count, 1), 14)
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

        phase = .working("Finding the best places…")
        let output = await AutoPlanService.build(prefs: prefs,
                                                 center: center,
                                                 mustSees: mustSees,
                                                 keys: secrets.keys)
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

        draft = ImportDraft()
        draft.load(plan: output.days, themes: themes, tripDays: trip.sortedDays)
        notice = output.notices.isEmpty ? nil : output.notices.joined(separator: " ")
        phase = .review
    }

    /// Removes the stops of the days the new plan is about to fill.
    private func clearTargetDays() {
        let days = trip.sortedDays
        for index in Set(draft.days.map(\.targetIndex)) where days.indices.contains(index) {
            for stop in Array(days[index].stops) {
                context.delete(stop)
            }
        }
    }
}
