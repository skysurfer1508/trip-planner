import Foundation
import SwiftData

// MARK: - What goes over the wire

struct SyncDelta: Encodable {
    var base: SyncValue
    var new: SyncValue
}

/// One thing the app changed since the last sync: `fields` hold, per field, the value the app started from and the new one.
struct SyncChange: Encodable {
    var kind: String
    var id: String
    var op: String
    var fields: [String: SyncDelta]?
}

struct SyncConflict: Decodable {
    var kind: String
    var id: String
    var label: String?
    var field: String
    var server: SyncValue?
    var app: SyncValue?
}

struct SyncServerChange: Decodable {
    var kind: String
    var id: String
    var deleted: Bool
    var fields: SyncFields?
}

struct SyncResponse: Decodable {
    var tripID: String
    var revision: Int
    var conflicts: [SyncConflict]
    var changes: [SyncServerChange]

    enum CodingKeys: String, CodingKey {
        case tripID = "trip_id"
        case revision, conflicts, changes
    }
}

// MARK: - Snapshots

struct SyncItem {
    var kind: String
    var id: String
    var fields: SyncFields
}

/// The trip as it is on the phone right now.
struct SyncSnapshot {
    var trip = SyncFields()
    var days: [String: SyncFields] = [:]       // by date ("2027-07-19")
    var items: [String: SyncItem] = [:]        // by "kind:id"

    /// One flat map ("trip", "day:<date>", "<kind>:<id>") that is also what is stored as the base of the next sync.
    var flat: SyncBase {
        var out = SyncBase()
        out["trip"] = trip
        for (date, fields) in days { out["day:" + date] = fields }
        for (key, item) in items { out[key] = item.fields }
        return out
    }
}

typealias SyncBase = [String: SyncFields]

enum SyncEngine {
    static let itemKinds = ["stop", "booking", "expense", "checklist_item"]

    static func newID() -> String { UUID().uuidString.lowercased() }

    static func key(_ kind: String, _ id: String) -> String { kind + ":" + id }

    // MARK: Reading the phone

    /// The trip's current state. Items that have no sync id yet get one here.
    static func snapshot(of trip: Trip, codec: SyncCodec) -> SyncSnapshot {
        var out = SyncSnapshot()
        out.trip = codec.fields(of: trip)
        for day in trip.days {
            let date = codec.dayString(day.date)
            var notes = SyncFields()
            notes["notes"] = .string(String(day.notes.prefix(4000)))
            out.days[date] = notes
            for stop in day.stops {
                if stop.syncID.isEmpty { stop.syncID = newID() }
                out.items[key("stop", stop.syncID)] = SyncItem(kind: "stop", id: stop.syncID, fields: codec.fields(of: stop, dayDate: day.date))
            }
        }
        for booking in trip.bookings {
            if booking.syncID.isEmpty { booking.syncID = newID() }
            out.items[key("booking", booking.syncID)] = SyncItem(kind: "booking", id: booking.syncID, fields: codec.fields(of: booking))
        }
        for expense in trip.expenses {
            if expense.syncID.isEmpty { expense.syncID = newID() }
            out.items[key("expense", expense.syncID)] = SyncItem(kind: "expense", id: expense.syncID, fields: codec.fields(of: expense))
        }
        for item in trip.checklist {
            if item.syncID.isEmpty { item.syncID = newID() }
            out.items[key("checklist_item", item.syncID)] = SyncItem(kind: "checklist_item", id: item.syncID, fields: codec.fields(of: item))
        }
        return out
    }

    // MARK: What to send

    private static func delta(current: SyncFields, base: SyncFields?) -> [String: SyncDelta] {
        var out: [String: SyncDelta] = [:]
        for (field, value) in current {
            let before = base?[field] ?? .null
            if !value.matches(before) { out[field] = SyncDelta(base: before, new: value) }
        }
        return out
    }

    static func changes(current: SyncSnapshot, base: SyncBase) -> [SyncChange] {
        var out: [SyncChange] = []
        if let before = base["trip"] {
            let d = delta(current: current.trip, base: before)
            if !d.isEmpty { out.append(SyncChange(kind: "trip", id: "trip", op: "upsert", fields: d)) }
        }
        for (date, fields) in current.days.sorted(by: { $0.key < $1.key }) {
            let d = delta(current: fields, base: base["day:" + date])
            if !d.isEmpty { out.append(SyncChange(kind: "day", id: date, op: "upsert", fields: d)) }
        }
        for (itemKey, item) in current.items.sorted(by: { $0.key < $1.key }) {
            let d = delta(current: item.fields, base: base[itemKey])
            if !d.isEmpty { out.append(SyncChange(kind: item.kind, id: item.id, op: "upsert", fields: d)) }
        }
        for itemKey in base.keys.sorted() where current.items[itemKey] == nil {
            guard let colon = itemKey.firstIndex(of: ":") else { continue }
            let kind = String(itemKey[..<colon])
            guard itemKinds.contains(kind) else { continue }
            out.append(SyncChange(kind: kind, id: String(itemKey[itemKey.index(after: colon)...]), op: "delete", fields: nil))
        }
        return out
    }

    // MARK: Taking over the server's answer

    struct Outcome {
        var skipped: Set<String> = []
        var fromServer: Set<String> = []
    }

    /// Applies what the server sent. Whatever the person changed on the phone while the request was running is left alone (it goes out
    /// with the next sync). Afterwards the trip's base, revision and time are updated.
    @MainActor
    @discardableResult
    static func apply(_ response: SyncResponse, to trip: Trip, context: ModelContext, pushed: SyncSnapshot, oldBase: SyncBase, codec: SyncCodec) -> Outcome {
        var outcome = Outcome()
        let nowFlat = snapshot(of: trip, codec: codec).flat
        let pushedFlat = pushed.flat

        /// Edited on the phone since the data was sent (or created since)?
        func editedMeanwhile(_ itemKey: String) -> Bool {
            switch (nowFlat[itemKey], pushedFlat[itemKey]) {
            case let (now?, before?): return !now.matches(before)
            case (nil, nil): return false
            case (nil, _?): return true       // deleted on the phone meanwhile
            case (_?, nil): return true       // created on the phone meanwhile
            }
        }

        func day(on date: String) -> Day? { trip.days.first { codec.dayString($0.date) == date } }

        func ensureDay(_ date: String) -> Day? {
            if let found = day(on: date) { return found }
            guard let start = codec.parseDay(date) else { return nil }
            let created = Day(date: start)
            context.insert(created)
            trip.days.append(created)
            return created
        }

        func stop(_ id: String) -> Stop? { trip.days.flatMap { $0.stops }.first { $0.syncID == id } }

        func move(_ model: Stop, toDay date: String) {
            guard let target = ensureDay(date), model.day !== target else { return }
            model.day?.stops.removeAll { $0 === model }
            target.stops.append(model)
        }

        func applyFields(_ fields: SyncFields, kind: String, id: String, itemKey: String) {
            switch kind {
            case "trip":
                codec.apply(fields, to: trip)
            case "day":
                if let target = ensureDay(id), let notes = fields["notes"]?.string { target.notes = notes }
            case "stop":
                let model: Stop
                if let found = stop(id) {
                    model = found
                } else {
                    guard let date = fields["day"]?.string, let target = ensureDay(date) else { return }
                    model = Stop(name: fields["name"]?.string ?? "Stop", latitude: 0, longitude: 0)
                    model.syncID = id
                    context.insert(model)
                    target.stops.append(model)
                }
                codec.apply(fields, to: model)
                if let date = fields["day"]?.string { move(model, toDay: date) }
            case "booking":
                let model: Booking
                if let found = trip.bookings.first(where: { $0.syncID == id }) {
                    model = found
                } else {
                    model = Booking(kind: .hotel, title: fields["title"]?.string ?? "", startDate: Date(), endDate: Date())
                    model.syncID = id
                    context.insert(model)
                    model.trip = trip
                }
                codec.apply(fields, to: model)
            case "expense":
                let model: Expense
                if let found = trip.expenses.first(where: { $0.syncID == id }) {
                    model = found
                } else {
                    model = Expense(title: fields["title"]?.string ?? "", amount: 0, currencyCode: trip.currencyCode, category: .other, date: Date())
                    model.syncID = id
                    context.insert(model)
                    model.trip = trip
                }
                codec.apply(fields, to: model)
            case "checklist_item":
                let model: ChecklistItem
                if let found = trip.checklist.first(where: { $0.syncID == id }) {
                    model = found
                } else {
                    model = ChecklistItem(title: fields["title"]?.string ?? "", section: "")
                    model.syncID = id
                    context.insert(model)
                    model.trip = trip
                }
                codec.apply(fields, to: model)
            default:
                break
            }
        }

        func remove(kind: String, id: String) {
            switch kind {
            case "stop":
                if let model = stop(id) {
                    model.day?.stops.removeAll { $0 === model }
                    context.delete(model)
                }
            case "booking":
                if let model = trip.bookings.first(where: { $0.syncID == id }) {
                    trip.bookings.removeAll { $0 === model }
                    context.delete(model)
                }
            case "expense":
                if let model = trip.expenses.first(where: { $0.syncID == id }) {
                    trip.expenses.removeAll { $0 === model }
                    context.delete(model)
                }
            case "checklist_item":
                if let model = trip.checklist.first(where: { $0.syncID == id }) {
                    trip.checklist.removeAll { $0 === model }
                    context.delete(model)
                }
            default:
                break
            }
        }

        func keyOf(kind: String, id: String) -> String {
            switch kind {
            case "trip": return "trip"
            case "day": return "day:" + id
            default: return key(kind, id)
            }
        }

        for change in response.changes {
            let itemKey = keyOf(kind: change.kind, id: change.id)
            outcome.fromServer.insert(itemKey)
            if editedMeanwhile(itemKey) { outcome.skipped.insert(itemKey); continue }
            if change.deleted { remove(kind: change.kind, id: change.id) }
            else if let fields = change.fields { applyFields(fields, kind: change.kind, id: change.id, itemKey: itemKey) }
        }

        // Where both sides changed the same field, the server's value stays; the phone takes it over.
        for conflict in response.conflicts where conflict.field != "deleted" {
            guard let value = conflict.server else { continue }
            let id = conflict.kind == "day" ? (conflict.label ?? conflict.id) : conflict.id
            let itemKey = keyOf(kind: conflict.kind, id: id)
            if editedMeanwhile(itemKey) { outcome.skipped.insert(itemKey); continue }
            var fields = SyncFields()
            fields[conflict.field] = value
            applyFields(fields, kind: conflict.kind, id: id, itemKey: itemKey)
            outcome.fromServer.insert(itemKey)
        }

        trip.syncDays()

        // The new base is what both sides have now. Items the person created or changed during the request stay as they were,
        // so the next sync sends them.
        var newBase = snapshot(of: trip, codec: codec).flat
        for itemKey in newBase.keys where pushedFlat[itemKey] == nil && !outcome.fromServer.contains(itemKey) && !itemKey.hasPrefix("day:") {
            newBase[itemKey] = nil
        }
        for itemKey in outcome.skipped { newBase[itemKey] = oldBase[itemKey] }
        trip.syncBase = encode(newBase)
        trip.syncRevision = response.revision
        trip.syncedAt = Date()
        return outcome
    }

    // MARK: Storing the base

    static func encode(_ base: SyncBase) -> Data? { try? JSONEncoder().encode(base) }

    static func decodeBase(_ data: Data?) -> SyncBase {
        guard let data, let base = try? JSONDecoder().decode(SyncBase.self, from: data) else { return [:] }
        return base
    }
}
