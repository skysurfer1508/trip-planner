import Foundation

/// Turns the app's models into the fields the website uses and back. Times are local wall-clock strings
/// ("2027-07-20T09:30"), built with the device's calendar like everywhere else in the app.
struct SyncCodec {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        dayFormatter = Self.formatter("yyyy-MM-dd", zone: calendar.timeZone)
        timeFormatter = Self.formatter("yyyy-MM-dd'T'HH:mm", zone: calendar.timeZone)
    }

    // MARK: Dates

    private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    private let dayFormatter: DateFormatter
    private let timeFormatter: DateFormatter

    func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }

    func parseDay(_ text: String) -> Date? {
        guard let date = dayFormatter.date(from: String(text.prefix(10))) else { return nil }
        return calendar.startOfDay(for: date)
    }

    func parseTime(_ text: String) -> Date? {
        timeFormatter.date(from: String(text.prefix(16)))
    }

    // MARK: Helpers

    private func clean(_ text: String, limit: Int = 4000) -> SyncValue { .string(String(text.prefix(limit))) }

    /// Only http(s) links are accepted by the website.
    private func link(_ text: String) -> SyncValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return .string(lower.hasPrefix("http://") || lower.hasPrefix("https://") ? String(trimmed.prefix(2000)) : "")
    }

    private func latitude(_ value: Double) -> SyncValue { .number((-90...90).contains(value) ? value : 0) }
    private func longitude(_ value: Double) -> SyncValue { .number((-180...180).contains(value) ? value : 0) }

    // MARK: Trip

    func fields(of trip: Trip) -> SyncFields {
        var out = SyncFields()
        out["name"] = clean(trip.name, limit: 100)
        out["destination"] = clean(trip.destination, limit: 100)
        out["start_date"] = .string(dayString(trip.startDate))
        out["end_date"] = .string(dayString(max(trip.endDate, trip.startDate)))
        out["currency_code"] = .string(String(trip.currencyCode.prefix(3)))
        out["budget"] = .number(max(0, trip.budget))
        let transports = ["walking", "transit", "car"]
        out["transport_raw"] = .string(transports.contains(trip.transportRaw) ? trip.transportRaw : "walking")
        out["time_zone"] = clean(trip.timeZoneID, limit: 60)
        out["country_code"] = .string(String(trip.countryCode.prefix(2)))
        if trip.hasDestinationCoordinate {
            out["destination_latitude"] = latitude(trip.destinationLatitude)
            out["destination_longitude"] = longitude(trip.destinationLongitude)
        } else {
            out["destination_latitude"] = .number(0)
            out["destination_longitude"] = .number(0)
        }
        return out
    }

    func apply(_ f: SyncFields, to trip: Trip) {
        if let v = f["name"]?.string { trip.name = v }
        if let v = f["destination"]?.string { trip.destination = v }
        if let v = f["start_date"]?.string, let d = parseDay(v) { trip.startDate = d }
        if let v = f["end_date"]?.string, let d = parseDay(v) { trip.endDate = d }
        if let v = f["currency_code"]?.string, !v.isEmpty { trip.currencyCode = v }
        if let v = f["budget"]?.number { trip.budget = v }
        if let v = f["transport_raw"]?.string, !v.isEmpty { trip.transportRaw = v }
        if let v = f["time_zone"]?.string { trip.timeZoneID = v }
        if let v = f["country_code"]?.string { trip.countryCode = v }
        if let lat = f["destination_latitude"]?.number, let lon = f["destination_longitude"]?.number {
            trip.destinationLatitude = lat
            trip.destinationLongitude = lon
            trip.hasDestinationCoordinate = lat != 0 || lon != 0
        }
    }

    // MARK: Stop

    func fields(of stop: Stop, dayDate: Date) -> SyncFields {
        var out = SyncFields()
        out["day"] = .string(dayString(dayDate))
        out["name"] = clean(stop.name.isEmpty ? "Stop" : stop.name, limit: 200)
        out["address"] = clean(stop.address, limit: 300)
        out["category_raw"] = .string(stop.categoryRaw)
        if let planned = stop.plannedTime {
            out["planned_time"] = SyncValue.string(timeString(planned))
        } else {
            out["planned_time"] = SyncValue.null
        }
        out["duration_minutes"] = .number(Double(min(max(stop.durationMinutes, 0), 1440)))
        out["notes"] = clean(stop.notes)
        out["sort_order"] = .number(Double(stop.order))
        out["is_done"] = .bool(stop.isDone)
        out["estimated_cost"] = .number(max(0, stop.estimatedCost))
        out["phone"] = clean(stop.phone, limit: 60)
        out["website"] = link(stop.website)
        out["opening_hours"] = clean(stop.openingHours, limit: 500)
        out["latitude"] = latitude(stop.latitude)
        out["longitude"] = longitude(stop.longitude)
        return out
    }

    /// Everything but the day, which the engine places.
    func apply(_ f: SyncFields, to stop: Stop) {
        if let v = f["name"]?.string { stop.name = v }
        if let v = f["address"]?.string { stop.address = v }
        if let v = f["category_raw"]?.string, !v.isEmpty { stop.categoryRaw = v }
        if let v = f["planned_time"] { stop.plannedTime = v.string.flatMap { parseTime($0) } }
        if let v = f["duration_minutes"]?.int { stop.durationMinutes = v }
        if let v = f["notes"]?.string { stop.notes = v }
        if let v = f["sort_order"]?.int { stop.order = v }
        if let v = f["is_done"]?.bool { stop.isDone = v }
        if let v = f["estimated_cost"]?.number { stop.estimatedCost = v }
        if let v = f["phone"]?.string { stop.phone = v }
        if let v = f["website"]?.string { stop.website = v }
        if let v = f["opening_hours"]?.string { stop.openingHours = v }
        if let v = f["latitude"]?.number { stop.latitude = v }
        if let v = f["longitude"]?.number { stop.longitude = v }
    }

    // MARK: Booking

    func fields(of booking: Booking) -> SyncFields {
        var out = SyncFields()
        out["kind_raw"] = .string(booking.kindRaw)
        out["title"] = clean(booking.title.isEmpty ? "Booking" : booking.title, limit: 200)
        out["start_date"] = .string(timeString(booking.startDate))
        out["end_date"] = .string(timeString(booking.endDate))
        out["place_name"] = clean(booking.placeName, limit: 200)
        out["other_end"] = clean(booking.otherEnd, limit: 200)
        out["address"] = clean(booking.address, limit: 300)
        out["reference"] = clean(booking.reference, limit: 100)
        out["notes"] = clean(booking.notes)
        out["buffer_minutes"] = .number(Double(min(max(booking.bufferMinutes, 0), 1440)))
        out["remind"] = .bool(booking.remind)
        out["phone"] = clean(booking.phone, limit: 60)
        out["website"] = link(booking.website)
        // Without a position the website must not get 0/0 (it would count as a position).
        if booking.hasCoordinate {
            out["latitude"] = latitude(booking.latitude)
            out["longitude"] = longitude(booking.longitude)
        }
        return out
    }

    func apply(_ f: SyncFields, to booking: Booking) {
        if let v = f["kind_raw"]?.string, !v.isEmpty { booking.kindRaw = v }
        if let v = f["title"]?.string { booking.title = v }
        if let v = f["start_date"]?.string, let d = parseTime(v) { booking.startDate = d }
        if let v = f["end_date"]?.string, let d = parseTime(v) { booking.endDate = d }
        if let v = f["place_name"]?.string { booking.placeName = v }
        if let v = f["other_end"]?.string { booking.otherEnd = v }
        if let v = f["address"]?.string { booking.address = v }
        if let v = f["reference"]?.string { booking.reference = v }
        if let v = f["notes"]?.string { booking.notes = v }
        if let v = f["buffer_minutes"]?.int { booking.bufferMinutes = v }
        if let v = f["remind"]?.bool { booking.remind = v }
        if let v = f["phone"]?.string { booking.phone = v }
        if let v = f["website"]?.string { booking.website = v }
        if let lat = f["latitude"]?.number, let lon = f["longitude"]?.number {
            booking.latitude = lat
            booking.longitude = lon
            booking.hasCoordinate = lat != 0 || lon != 0
        }
    }

    // MARK: Expense

    func fields(of expense: Expense) -> SyncFields {
        var out = SyncFields()
        out["title"] = clean(expense.title.isEmpty ? "Expense" : expense.title, limit: 200)
        out["amount"] = .number(expense.amount)
        out["currency_code"] = .string(String(expense.currencyCode.prefix(3)))
        out["category_raw"] = .string(expense.categoryRaw)
        out["date"] = .string(dayString(expense.date))
        return out
    }

    func apply(_ f: SyncFields, to expense: Expense) {
        if let v = f["title"]?.string { expense.title = v }
        if let v = f["amount"]?.number { expense.amount = v }
        if let v = f["currency_code"]?.string, !v.isEmpty { expense.currencyCode = v }
        if let v = f["category_raw"]?.string, !v.isEmpty { expense.categoryRaw = v }
        if let v = f["date"]?.string, let d = parseDay(v) { expense.date = d }
    }

    // MARK: Checklist

    func fields(of item: ChecklistItem) -> SyncFields {
        var out = SyncFields()
        out["title"] = clean(item.title.isEmpty ? "Item" : item.title, limit: 200)
        out["section"] = clean(item.section, limit: 100)
        out["is_done"] = .bool(item.isDone)
        out["sort_order"] = .number(Double(item.order))
        return out
    }

    func apply(_ f: SyncFields, to item: ChecklistItem) {
        if let v = f["title"]?.string { item.title = v }
        if let v = f["section"]?.string { item.section = v }
        if let v = f["is_done"]?.bool { item.isDone = v }
        if let v = f["sort_order"]?.int { item.order = v }
    }
}
