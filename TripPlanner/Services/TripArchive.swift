import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// The `.tripplanner` file: a trip (or a backup of all trips) as JSON.
    static let tripPlanner = UTType(exportedAs: "com.skysurfer.tripplanner.trip", conformingTo: .json)
}

// MARK: - File format

struct TripArchive: Codable {
    static let currentVersion = 1

    var version = TripArchive.currentVersion
    var exportedAt = Date()
    var trips: [TripDTO]
}

struct TripDTO: Codable {
    var name: String
    var destination: String
    var startDate: Date
    var endDate: Date
    var destinationLatitude: Double
    var destinationLongitude: Double
    var hasDestinationCoordinate: Bool
    var budget: Double
    var currencyCode: String
    var days: [DayDTO]
    var expenses: [ExpenseDTO]
    var checklist: [ChecklistDTO]
    var savedPlaces: [SavedPlaceDTO]
    var documents: [DocumentDTO]
}

struct DayDTO: Codable {
    var date: Date
    var notes: String
    var stops: [StopDTO]
}

struct StopDTO: Codable {
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String
    var categoryRaw: String
    var plannedTime: Date?
    var durationMinutes: Int
    var notes: String
    var order: Int
    var isDone: Bool
    var estimatedCost: Double
    var phone: String
    var website: String
    var aiTips: String
}

struct ExpenseDTO: Codable {
    var title: String
    var amount: Double
    var currencyCode: String
    var categoryRaw: String
    var date: Date
}

struct ChecklistDTO: Codable {
    var title: String
    var section: String
    var isDone: Bool
    var order: Int
}

struct SavedPlaceDTO: Codable {
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String
    var categoryRaw: String
    var savedAt: Date
}

struct DocumentDTO: Codable {
    var title: String
    var fileName: String
    var kindRaw: String
    var note: String
    var addedAt: Date
    var data: Data?
}

enum TripArchiveError: LocalizedError {
    case unreadable
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This isn't a Trip Planner file, or it is damaged."
        case .newerVersion: "This file was made by a newer version of the app. Update the app and try again."
        }
    }
}

// MARK: - Converting models

enum TripArchiver {
    static func archive(_ trips: [Trip], includeDocuments: Bool) -> TripArchive {
        TripArchive(trips: trips.map { dto($0, includeDocuments: includeDocuments) })
    }

    private static func dto(_ trip: Trip, includeDocuments: Bool) -> TripDTO {
        TripDTO(
            name: trip.name,
            destination: trip.destination,
            startDate: trip.startDate,
            endDate: trip.endDate,
            destinationLatitude: trip.destinationLatitude,
            destinationLongitude: trip.destinationLongitude,
            hasDestinationCoordinate: trip.hasDestinationCoordinate,
            budget: trip.budget,
            currencyCode: trip.currencyCode,
            days: trip.sortedDays.map { day in
                DayDTO(date: day.date, notes: day.notes, stops: day.sortedStops.map { stop in
                    StopDTO(name: stop.name, latitude: stop.latitude, longitude: stop.longitude,
                            address: stop.address, categoryRaw: stop.categoryRaw, plannedTime: stop.plannedTime,
                            durationMinutes: stop.durationMinutes, notes: stop.notes, order: stop.order,
                            isDone: stop.isDone, estimatedCost: stop.estimatedCost, phone: stop.phone,
                            website: stop.website, aiTips: stop.aiTips)
                })
            },
            expenses: trip.expenses.sorted { $0.date < $1.date }.map {
                ExpenseDTO(title: $0.title, amount: $0.amount, currencyCode: $0.currencyCode,
                           categoryRaw: $0.categoryRaw, date: $0.date)
            },
            checklist: trip.checklist.sorted { $0.order < $1.order }.map {
                ChecklistDTO(title: $0.title, section: $0.section, isDone: $0.isDone, order: $0.order)
            },
            savedPlaces: trip.savedPlaces.map {
                SavedPlaceDTO(name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                              address: $0.address, categoryRaw: $0.categoryRaw, savedAt: $0.savedAt)
            },
            documents: includeDocuments
                ? trip.documents.map {
                    DocumentDTO(title: $0.title, fileName: $0.fileName, kindRaw: $0.kindRaw,
                                note: $0.note, addedAt: $0.addedAt, data: $0.data)
                }
                : []
        )
    }

    // MARK: Encoding

    static func encode(_ archive: TripArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> TripArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(TripArchive.self, from: data) else {
            throw TripArchiveError.unreadable
        }
        guard archive.version <= TripArchive.currentVersion else {
            throw TripArchiveError.newerVersion(archive.version)
        }
        return archive
    }

    /// Writes the trips to a temporary `.tripplanner` file and returns its URL.
    static func writeFile(for trips: [Trip], includeDocuments: Bool, name: String? = nil) throws -> URL {
        let data = try encode(archive(trips, includeDocuments: includeDocuments))
        let base = name ?? (trips.count == 1 ? trips[0].name : "Trip Planner backup")
        let safe = base.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe.isEmpty ? "trip" : safe)
            .appendingPathExtension("tripplanner")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Importing

    /// Creates new trips from the archive (existing trips are never touched) and returns them.
    @discardableResult
    static func insert(_ archive: TripArchive, into context: ModelContext) -> [Trip] {
        archive.trips.map { dto in
            let trip = Trip(name: dto.name, destination: dto.destination, startDate: dto.startDate, endDate: dto.endDate)
            context.insert(trip)
            trip.destinationLatitude = dto.destinationLatitude
            trip.destinationLongitude = dto.destinationLongitude
            trip.hasDestinationCoordinate = dto.hasDestinationCoordinate
            trip.budget = dto.budget
            trip.currencyCode = dto.currencyCode

            for dayDTO in dto.days {
                let day = Day(date: dayDTO.date)
                context.insert(day)
                day.notes = dayDTO.notes
                trip.days.append(day)
                for stopDTO in dayDTO.stops {
                    let stop = Stop(name: stopDTO.name, latitude: stopDTO.latitude, longitude: stopDTO.longitude,
                                    address: stopDTO.address,
                                    category: StopCategory(rawValue: stopDTO.categoryRaw) ?? .other)
                    context.insert(stop)
                    stop.plannedTime = stopDTO.plannedTime
                    stop.durationMinutes = stopDTO.durationMinutes
                    stop.notes = stopDTO.notes
                    stop.order = stopDTO.order
                    stop.isDone = stopDTO.isDone
                    stop.estimatedCost = stopDTO.estimatedCost
                    stop.phone = stopDTO.phone
                    stop.website = stopDTO.website
                    stop.aiTips = stopDTO.aiTips
                    day.stops.append(stop)
                }
            }
            for e in dto.expenses {
                let expense = Expense(title: e.title, amount: e.amount, currencyCode: e.currencyCode,
                                      category: ExpenseCategory(rawValue: e.categoryRaw) ?? .other, date: e.date)
                context.insert(expense)
                expense.trip = trip
            }
            for c in dto.checklist {
                let item = ChecklistItem(title: c.title, section: c.section, order: c.order)
                context.insert(item)
                item.isDone = c.isDone
                item.trip = trip
            }
            for p in dto.savedPlaces {
                let place = SavedPlace(name: p.name, latitude: p.latitude, longitude: p.longitude,
                                       address: p.address, category: StopCategory(rawValue: p.categoryRaw) ?? .other)
                context.insert(place)
                place.savedAt = p.savedAt
                place.trip = trip
            }
            for d in dto.documents {
                guard let data = d.data else { continue }
                let document = TripDocument(title: d.title, fileName: d.fileName,
                                            kind: DocumentKind(rawValue: d.kindRaw) ?? .other, data: data)
                context.insert(document)
                document.note = d.note
                document.addedAt = d.addedAt
                document.trip = trip
            }
            return trip
        }
    }

    /// Reads a `.tripplanner` file and adds its trips. Throws a readable error for bad files.
    @discardableResult
    static func importFile(at url: URL, into context: ModelContext) throws -> [Trip] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return insert(try decode(data), into: context)
    }
}
