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

    /// Glyph tint on a neutral surface; reuses the stop-category tints (see `Theme.category`).
    var color: Color {
        switch self {
        case .food: Theme.category(.food)
        case .transport: Theme.category(.transport)
        case .lodging: Theme.category(.hotel)
        case .activities: Theme.category(.sight)
        case .shopping: Theme.category(.cafe)
        case .other: Theme.category(.other)
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
