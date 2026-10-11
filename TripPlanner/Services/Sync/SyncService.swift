import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import SwiftData
import SwiftUI

/// Talks to the website: signs in (Authentik, in the system sign-in sheet), uploads trips, downloads trips and syncs the ones that are linked.
/// The website keeps the session in a cookie; URLSession stores it in the shared cookie storage, which survives restarts.
@MainActor
@Observable
final class SyncService: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SyncError: LocalizedError {
        case signedOut
        case server(String)
        case network

        var errorDescription: String? {
            switch self {
            case .signedOut: "You are signed out. Please sign in again."
            case .server(let message): message
            case .network: "The website can't be reached."
            }
        }
    }

    struct ServerTrip: Decodable, Identifiable {
        var id: String
        var name: String
        var destination: String?
        var startDate: String
        var endDate: String
        var phase: String
        var role: String

        enum CodingKeys: String, CodingKey {
            case id, name, destination, phase, role
            case startDate = "start_date"
            case endDate = "end_date"
        }
    }

    static let defaultServer = "https://trip.skyserver1508.org"
    static let serverKey = "syncServerURL"
    static let callbackScheme = "tripplanner"
    static let sessionCookieName = "session"

    /// The address of the website. Kept in UserDefaults (a computed property, because property observers do not mix with @Observable).
    var serverURLString: String {
        get { UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer }
        set { UserDefaults.standard.set(newValue, forKey: Self.serverKey) }
    }
    private(set) var signedIn = false
    private(set) var busy = false
    var message: String?
    private(set) var lastRun: Date?
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        signedIn = hasSessionCookie()
    }

    var baseURL: URL? {
        var text = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else { return nil }
        return url
    }

    private func hasSessionCookie() -> Bool {
        guard let base = baseURL else { return false }
        let cookies = HTTPCookieStorage.shared.cookies(for: base) ?? []
        return cookies.contains { $0.name == Self.sessionCookieName && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    // MARK: Signing in

    func signIn() async {
        message = nil
        guard let base = baseURL else { message = "The address of the website is not valid. It must start with https://"; return }
        let verifier = Self.randomVerifier()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/app/login"
        components.queryItems = [URLQueryItem(name: "challenge", value: Self.challenge(for: verifier))]
        do {
            let callback = try await authenticate(components.url!)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw SyncError.server("The sign-in did not return a code.")
            }
            try await exchange(code: code, verifier: verifier, base: base)
            signedIn = true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // closed by the person: nothing to say
        } catch {
            message = "Sign-in did not work. \(error.localizedDescription)"
        }
    }

    func signOut() {
        if let base = baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: base) {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        signedIn = false
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback) } else { continuation.resume(throwing: error ?? SyncError.signedOut) }
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            session = web
            if !web.start() { continuation.resume(throwing: SyncError.signedOut) }
        }
    }

    private func exchange(code: String, verifier: String, base: URL) async throws {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "verifier", value: verifier)]
        var request = URLRequest(url: base.appendingPathComponent("app/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw SyncError.server("The website did not accept the sign-in.") }
        guard hasSessionCookie() else { throw SyncError.server("The website did not start a session.") }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Requests

    private func send(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let base = baseURL else { throw SyncError.server("The address of the website is not valid.") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-Trip-Client")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw SyncError.network }
        guard let http = response as? HTTPURLResponse else { throw SyncError.network }
        if http.statusCode == 401 { signedIn = false; throw SyncError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw SyncError.server(detail ?? "The website answered with an error (\(http.statusCode)).")
        }
        return data
    }

    /// Trips on the website that can be synced (building phase) and that this person may change.
    func serverTrips() async throws -> [ServerTrip] {
        let data = try await send(path: "api/trips")
        let all = try JSONDecoder().decode([ServerTrip].self, from: data)
        return all.filter { $0.phase == "building" }
    }

    private struct Request: Encodable {
        var tripID: String
        var since: Int
        var changes: [SyncChange]

        enum CodingKeys: String, CodingKey {
            case tripID = "trip_id"
            case since, changes
        }
    }

    private struct UploadItem: Encodable {
        var id: String
        var fields: SyncFields
    }

    private struct UploadDay: Encodable {
        var date: String
        var notes: String
    }

    private struct UploadSnapshot: Encodable {
        var trip: SyncFields
        var days: [UploadDay]
        var stops: [UploadItem]
        var bookings: [UploadItem]
        var expenses: [UploadItem]
        var checklist: [UploadItem]
    }

    private struct UploadRequest: Encodable {
        var snapshot: UploadSnapshot
    }

    // MARK: Syncing

    struct Report {
        var sent = 0
        var conflicts: [String] = []
    }

    /// One round for a trip that is already linked.
    @discardableResult
    func sync(_ trip: Trip, context: ModelContext) async throws -> Report {
        guard !trip.syncTripID.isEmpty else { return Report() }
        let codec = SyncCodec()
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        let oldBase = SyncEngine.decodeBase(trip.syncBase)
        let changes = SyncEngine.changes(current: pushed, base: oldBase)
        let body = try JSONEncoder().encode(Request(tripID: trip.syncTripID, since: trip.syncRevision, changes: changes))
        let response = try JSONDecoder().decode(SyncResponse.self, from: try await send(path: "api/sync", method: "POST", body: body))
        SyncEngine.apply(response, to: trip, context: context, pushed: pushed, oldBase: oldBase, codec: codec)
        try? context.save()
        return Report(sent: changes.count, conflicts: Self.describe(response.conflicts))
    }

    /// Sends a trip that has never been on the website. It gets linked to the copy that is created there.
    func upload(_ trip: Trip, context: ModelContext) async throws {
        let codec = SyncCodec()
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        func items(_ kind: String) -> [UploadItem] {
            pushed.items.values.filter { $0.kind == kind }.sorted { $0.id < $1.id }.map { UploadItem(id: $0.id, fields: $0.fields) }
        }
        let days = pushed.days.sorted { $0.key < $1.key }.map { UploadDay(date: $0.key, notes: $0.value["notes"]?.string ?? "") }
        let snapshot = UploadSnapshot(trip: pushed.trip, days: days, stops: items("stop"), bookings: items("booking"),
                                      expenses: items("expense"), checklist: items("checklist_item"))
        let body = try JSONEncoder().encode(UploadRequest(snapshot: snapshot))
        let response = try JSONDecoder().decode(SyncResponse.self, from: try await send(path: "api/sync", method: "POST", body: body))
        trip.syncTripID = response.tripID
        trip.syncRevision = 0
        trip.syncBase = nil
        SyncEngine.apply(response, to: trip, context: context, pushed: pushed, oldBase: [:], codec: codec)
        try? context.save()
    }

    /// Makes a local copy of a trip that exists on the website.
    func download(_ serverTrip: ServerTrip, context: ModelContext) async throws -> Trip {
        let body = try JSONEncoder().encode(Request(tripID: serverTrip.id, since: 0, changes: []))
        let response = try JSONDecoder().decode(SyncResponse.self, from: try await send(path: "api/sync", method: "POST", body: body))
        let codec = SyncCodec()
        let start = codec.parseDay(serverTrip.startDate) ?? Date()
        let trip = Trip(name: serverTrip.name, destination: serverTrip.destination ?? "", startDate: start, endDate: codec.parseDay(serverTrip.endDate) ?? start)
        context.insert(trip)
        trip.syncTripID = serverTrip.id
        let pushed = SyncEngine.snapshot(of: trip, codec: codec)
        SyncEngine.apply(response, to: trip, context: context, pushed: pushed, oldBase: [:], codec: codec)
        try? context.save()
        return trip
    }

    func unlink(_ trip: Trip) {
        trip.syncTripID = ""
        trip.syncRevision = 0
        trip.syncBase = nil
        trip.syncedAt = nil
    }

    /// Every linked trip, one after the other. Quiet: problems end up in `message`.
    func syncAll(_ trips: [Trip], context: ModelContext) async {
        guard signedIn, !busy else { return }
        let linked = trips.filter { !$0.syncTripID.isEmpty }
        guard !linked.isEmpty else { return }
        busy = true
        defer { busy = false }
        var conflicts: [String] = []
        for trip in linked {
            do { conflicts += try await sync(trip, context: context).conflicts }
            catch { message = "\(trip.name): \(error.localizedDescription)"; return }
        }
        lastRun = Date()
        message = conflicts.isEmpty ? nil : "Changed on both sides, the website's version was kept: " + conflicts.prefix(3).joined(separator: "; ")
    }

    static func describe(_ conflicts: [SyncConflict]) -> [String] {
        conflicts.map { "\($0.label ?? $0.kind) (\($0.field))" }
    }

    /// For the screens: run something with the busy flag and show a failure.
    func run(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await work() } catch { message = error.localizedDescription }
    }
}
