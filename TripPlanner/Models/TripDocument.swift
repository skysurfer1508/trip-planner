import Foundation
import SwiftData

enum DocumentKind: String, CaseIterable, Identifiable {
    case ticket, booking, identity, insurance, program, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ticket: "Tickets"
        case .booking: "Bookings"
        case .identity: "ID & visas"
        case .insurance: "Insurance"
        case .program: "Programs"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .ticket: "ticket.fill"
        case .booking: "building.2.fill"
        case .identity: "person.text.rectangle.fill"
        case .insurance: "cross.case.fill"
        case .program: "list.bullet.rectangle.fill"
        case .other: "doc.fill"
        }
    }
}

/// A file stored with the trip (ticket, booking, passport scan…). The bytes live in SwiftData's
/// external storage, so they are available offline.
@Model
final class TripDocument {
    var title: String = ""
    var fileName: String = ""
    var kindRaw: String = DocumentKind.other.rawValue
    var note: String = ""
    var addedAt: Date = Date()
    @Attribute(.externalStorage) var data: Data?
    var trip: Trip?

    init(title: String, fileName: String, kind: DocumentKind, data: Data) {
        self.title = title
        self.fileName = fileName
        self.kindRaw = kind.rawValue
        self.data = data
    }

    var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }
}
