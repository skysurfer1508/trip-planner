#if DEBUG
import Foundation
import SwiftData

/// In-memory data for SwiftUI previews only.
enum SampleData {
    @MainActor
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Trip.self, Day.self, Stop.self, Expense.self, ChecklistItem.self, TripDocument.self, SavedPlace.self, Booking.self, configurations: config)
        let context = container.mainContext

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 2, to: start)!
        let trip = Trip(name: "Lisbon weekend", destination: "Lisbon", startDate: start, endDate: end)
        context.insert(trip)
        trip.syncDays()

        if let first = trip.sortedDays.first {
            let stops = [
                Stop(name: "Time Out Market", latitude: 38.7066, longitude: -9.1459, address: "Av. 24 de Julho", category: .food),
                Stop(name: "Miradouro da Senhora do Monte", latitude: 38.7195, longitude: -9.1325, category: .sight),
                Stop(name: "Castelo de São Jorge", latitude: 38.7139, longitude: -9.1334, category: .sight),
            ]
            for (index, stop) in stops.enumerated() {
                first.append(stop)
                stop.plannedTime = calendar.date(bySettingHour: 10 + index * 2, minute: 0, second: 0, of: first.date)
            }
        }
        return container
    }()
}
#endif
