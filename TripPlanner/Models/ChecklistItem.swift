import Foundation
import SwiftData

/// One line of the packing list or the "before you go" to-do list.
@Model
final class ChecklistItem {
    var title: String = ""
    var section: String = ""
    var isDone: Bool = false
    var order: Int = 0
    var trip: Trip?

    init(title: String, section: String, order: Int = 0) {
        self.title = title
        self.section = section
        self.order = order
    }
}
