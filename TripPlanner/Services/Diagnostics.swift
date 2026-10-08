import Foundation

/// The last failed network calls, kept in memory so Settings -> Diagnostics can show and copy them.
/// Anything that talks to a free service writes to it through `Net`; nothing leaves the phone.
final class Diagnostics: @unchecked Sendable {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let service: String
        let message: String
    }

    static let shared = Diagnostics()
    static let capacity = 100

    private let lock = NSLock()
    private var stored: [Entry] = []

    /// Newest first.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored.reversed()
    }

    func record(service: String, message: String, date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(Entry(date: date, service: service, message: message))
        if stored.count > Self.capacity {
            stored.removeFirst(stored.count - Self.capacity)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored.removeAll()
    }

    /// A name for the service behind a URL: "overpass-api.de", "api.transitous.org".
    static func service(for url: URL?) -> String {
        url?.host ?? "unknown"
    }

    /// Plain text for the clipboard, with the app and system version on top.
    func report(appVersion: String, system: String, formatter: DateFormatter? = nil) -> String {
        let format = formatter ?? {
            let value = DateFormatter()
            value.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return value
        }()
        var lines = ["Trip Planner \(appVersion) on \(system)", "Failed requests (newest first):"]
        let list = entries
        if list.isEmpty { lines.append("none") }
        for entry in list {
            lines.append("\(format.string(from: entry.date))  \(entry.service)  \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}
