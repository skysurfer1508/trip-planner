import SwiftUI
import PhotosUI
import SwiftData
import Charts

struct BudgetView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @State private var rates: [String: Double]?
    @State private var showAdd = false
    @State private var showBudget = false
    @State private var editing: Expense?

    private struct CategoryTotal: Identifiable {
        let category: ExpenseCategory
        let amount: Double
        var id: String { category.rawValue }
    }

    private struct DayGroup: Identifiable {
        let date: Date
        let expenses: [Expense]
        var id: Date { date }
    }

    // MARK: Totals (everything in the trip's currency)

    private func converted(_ expense: Expense) -> Double {
        CurrencyService.convert(expense.amount, from: expense.currencyCode, base: trip.currencyCode, rates: rates)
            ?? expense.amount
    }

    private var hasUnconverted: Bool {
        trip.expenses.contains { $0.currencyCode != trip.currencyCode && rates?[$0.currencyCode] == nil }
    }

    private var spent: Double {
        trip.expenses.reduce(0) { $0 + converted($1) }
    }

    private var planned: Double {
        trip.days.flatMap(\.stops).reduce(0) { $0 + $1.estimatedCost }
    }

    private var categoryTotals: [CategoryTotal] {
        ExpenseCategory.allCases.compactMap { category in
            let sum = trip.expenses.filter { $0.category == category }.reduce(0) { $0 + converted($1) }
            return sum > 0 ? CategoryTotal(category: category, amount: sum) : nil
        }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trip.expenses) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { DayGroup(date: $0.key, expenses: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    private func money(_ value: Double, code: String? = nil) -> String {
        value.formatted(.currency(code: code ?? trip.currencyCode))
    }

    // MARK: Body

    var body: some View {
        List {
            summarySection

            if !categoryTotals.isEmpty {
                Section("By category") {
                    Chart(categoryTotals) { item in
                        BarMark(x: .value("Amount", item.amount),
                                y: .value("Category", item.category.title))
                            .foregroundStyle(item.category.color)
                    }
                    .frame(height: CGFloat(categoryTotals.count) * 36 + 24)
                }
            }

            if trip.expenses.isEmpty {
                Section {
                    ContentUnavailableView("No expenses yet", systemImage: "creditcard",
                                           description: Text("Add what you spend during the trip and see it against your budget."))
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.expenses) { expense in
                        Button {
                            editing = expense
                        } label: {
                            ExpenseRow(expense: expense, tripCurrency: trip.currencyCode, converted: converted(expense))
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            context.delete(group.expenses[index])
                        }
                    }
                } header: {
                    let total = group.expenses.reduce(0) { $0 + converted($1) }
                    HStack {
                        Text(group.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text(money(total))
                    }
                }
            }
        }
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            TabHeader(title: "Budget") {
                Button { showBudget = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Budget settings")
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel("Add expense")
            }
        }
        .sheet(isPresented: $showAdd) {
            ExpenseEditView(trip: trip, expense: nil, defaultDate: defaultDate)
        }
        .sheet(item: $editing) { expense in
            ExpenseEditView(trip: trip, expense: expense, defaultDate: expense.date)
        }
        .sheet(isPresented: $showBudget) {
            BudgetSettingsView(trip: trip)
        }
        .task(id: trip.currencyCode) {
            rates = await CurrencyService.shared.rates(base: trip.currencyCode)
        }
    }

    /// Today while the trip is running, else the first day.
    private var defaultDate: Date {
        trip.isActiveToday ? Date() : trip.startDate
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(money(spent))
                        .font(.title.bold())
                    Text(trip.budget > 0 ? "of \(money(trip.budget))" : "spent")
                        .foregroundStyle(.secondary)
                }
                if trip.budget > 0 {
                    ProgressView(value: min(spent, trip.budget), total: trip.budget)
                        .tint(spent > trip.budget ? Color.red : Color.accentColor)
                    let left = trip.budget - spent
                    Text(left >= 0 ? "\(money(left)) left" : "\(money(-left)) over budget")
                        .font(.subheadline)
                        .foregroundStyle(left >= 0 ? Color.secondary : Color.red)
                } else {
                    Button("Set a budget") { showBudget = true }
                        .font(.subheadline)
                }
            }
            .padding(.vertical, Spacing.xs)

            if planned > 0 {
                LabeledContent("Planned in stops", value: money(planned))
            }
            if hasUnconverted {
                Label("Some currencies couldn't be converted (offline or unsupported). They're counted at face value.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ExpenseRow: View {
    let expense: Expense
    let tripCurrency: String
    let converted: Double

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: expense.category.symbol)
                .frame(width: 32, height: 32)
                .background(expense.category.color.opacity(0.15), in: Circle())
                .foregroundStyle(expense.category.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title.isEmpty ? expense.category.title : expense.title)
                Text(expense.category.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(expense.amount.formatted(.currency(code: expense.currencyCode)))
                if expense.currencyCode != tripCurrency {
                    Text("≈ " + converted.formatted(.currency(code: tripCurrency)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct ExpenseEditView: View {
    let trip: Trip
    let expense: Expense?
    let defaultDate: Date

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var amountText = ""
    @State private var currency = "EUR"
    @State private var category: ExpenseCategory = .food
    @State private var date = Date()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var scanning = false
    @State private var scanMessage: String?

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                if expense == nil {
                    Section {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Scan a receipt from a photo", systemImage: "doc.viewfinder")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take a photo of a receipt", systemImage: "camera")
                            }
                        }
                        if scanning {
                            HStack(spacing: Spacing.m) {
                                ProgressView()
                                Text("Reading the receipt…").foregroundStyle(.secondary)
                            }
                        }
                        if let scanMessage {
                            Text(scanMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("The text on the photo is read on the phone. Check the amount before you save.")
                    }
                }
                Section {
                    TextField("What was it? (optional)", text: $title)
                    HStack {
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Currency", selection: $currency) {
                        ForEach(CurrencyList.codes(including: [trip.currencyCode, currency]), id: \.self) { code in
                            Text(CurrencyList.label(code)).tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(ExpenseCategory.allCases) { c in
                            Label(c.title, systemImage: c.symbol).tag(c)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                if let expense {
                    Section {
                        Button("Delete expense", role: .destructive) {
                            context.delete(expense)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(expense == nil ? "New expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled((amount ?? 0) <= 0)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await scan(image)
                    } else {
                        scanMessage = "That photo couldn't be opened."
                    }
                    photoItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image { Task { await scan(image) } }
                }
                .ignoresSafeArea()
            }
            .onAppear {
                currency = trip.currencyCode
                date = defaultDate
                if let expense {
                    title = expense.title
                    amountText = String(expense.amount)
                    currency = expense.currencyCode
                    category = expense.category
                    date = expense.date
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Reads the text on the photo and fills in what it finds.
    private func scan(_ image: UIImage) async {
        scanning = true
        scanMessage = nil
        defer { scanning = false }
        guard let text = try? await DocumentTextExtractor.recognize(image), !text.isEmpty else {
            scanMessage = "No text was found on the photo. Try again in better light, with the whole receipt in view."
            return
        }
        let result = ReceiptParser.parse(text)
        guard let found = result.amount else {
            scanMessage = "I couldn't find a total on the receipt. Type the amount in."
            return
        }
        amountText = String(format: "%.2f", found)
        if let code = result.currency { currency = code }
        if let day = result.date { date = day }
        if title.isEmpty, let merchant = result.merchant { title = merchant }
        if let guess = result.category { category = guess }
        scanMessage = "Found \(String(format: "%.2f", found)) \(result.currency ?? currency). Check it, then save."
    }

    private func save() {
        guard let amount, amount > 0 else { return }
        if let expense {
            expense.title = title
            expense.amount = amount
            expense.currencyCode = currency
            expense.category = category
            expense.date = date
        } else {
            let new = Expense(title: title, amount: amount, currencyCode: currency, category: category, date: date)
            context.insert(new)
            new.trip = trip
        }
        dismiss()
    }
}

struct BudgetSettingsView: View {
    @Bindable var trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var budgetText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Total budget", text: $budgetText)
                            .keyboardType(.decimalPad)
                        Text(trip.currencyCode)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Trip currency", selection: $trip.currencyCode) {
                        ForEach(CurrencyList.codes(including: [trip.currencyCode]), id: \.self) { code in
                            Text(CurrencyList.label(code)).tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("All totals are shown in the trip currency. Expenses in other currencies are converted with current exchange rates.")
                }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        trip.budget = Double(budgetText.replacingOccurrences(of: ",", with: ".")) ?? 0
                        dismiss()
                    }
                }
            }
            .onAppear {
                budgetText = trip.budget > 0 ? String(trip.budget) : ""
            }
        }
        .presentationDetents([.medium])
    }
}

enum CurrencyList {
    static func codes(including extra: [String]) -> [String] {
        Array(Set(Locale.commonISOCurrencyCodes + extra)).sorted()
    }

    static func label(_ code: String) -> String {
        let name = Locale.current.localizedString(forCurrencyCode: code) ?? ""
        return name.isEmpty ? code : "\(code) · \(name)"
    }
}
