import SwiftUI
import SwiftData

enum ExpenseCategory: String, CaseIterable, Identifiable {
    case food, transport, lodging, activities, shopping, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: "Food"
        case .transport: "Transport"
        case .lodging: "Lodging"
        case .activities: "Activities"
        case .shopping: "Shopping"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .transport: "tram.fill"
        case .lodging: "bed.double.fill"
        case .activities: "ticket.fill"
        case .shopping: "bag.fill"
        case .other: "ellipsis.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .food: .orange
        case .transport: .gray
        case .lodging: .indigo
        case .activities: .blue
        case .shopping: .pink
        case .other: .teal
        }
    }
}

@Model
final class Expense {
    var title: String = ""
    var amount: Double = 0
    var currencyCode: String = "EUR"
    var categoryRaw: String = ExpenseCategory.other.rawValue
    var date: Date = Date()
    var trip: Trip?

    init(title: String, amount: Double, currencyCode: String, category: ExpenseCategory, date: Date) {
        self.title = title
        self.amount = amount
        self.currencyCode = currencyCode
        self.categoryRaw = category.rawValue
        self.date = date
    }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
}
