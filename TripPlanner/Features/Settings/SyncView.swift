import SwiftData
import SwiftUI

/// Sync with the family website: sign in, send a trip there, bring a trip here, and keep linked trips up to date.
struct SyncView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @State private var serverTrips: [SyncService.ServerTrip] = []
    @State private var loaded = false

    private var linkedIDs: Set<String> { Set(trips.map(\.syncTripID).filter { !$0.isEmpty }) }
    private var downloadable: [SyncService.ServerTrip] { serverTrips.filter { !linkedIDs.contains($0.id) } }

    var body: some View {
        @Bindable var sync = sync

        Form {
            Section {
                Group {
                    TextField("Website", text: $sync.serverURLString, prompt: Text("https://trip.example.org").foregroundStyle(Theme.inkSecondary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .foregroundStyle(Theme.ink)
                        .frame(minHeight: 44)
                    if sync.signedIn {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                        Button("Sign out", role: .destructive) { sync.signOut(); serverTrips = []; loaded = false }
                            .frame(minHeight: 44)
                    } else {
                        Button("Sign in") { Task { await sync.signIn(); await reload() } }
                            .frame(minHeight: 44)
                    }
                }
                .listRowBackground(Theme.surface)
            } header: {
                Text("Account")
            } footer: {
                Text("You sign in with the same account as on the website. Only trips that are in the building phase there can be synced.")
            }

            if let message = sync.message {
                Section {
                    Text(message).foregroundStyle(Theme.ink).listRowBackground(Theme.surface)
                }
            }

            if sync.signedIn {
                Section {
                    Group {
                        Button {
                            Task { await sync.syncAll(trips, context: context); await reload() }
                        } label: {
                            HStack {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                if sync.busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sync.busy)
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Theme.surface)
                } footer: {
                    if let last = sync.lastRun {
                        Text("Last sync \(last.formatted(.relative(presentation: .named))).")
                    } else {
                        Text("Syncing also runs when you open the app.")
                    }
                }

                Section {
                    Group {
                        if trips.isEmpty { Text("No trips on this phone.").foregroundStyle(Theme.inkSecondary) }
                        ForEach(trips) { trip in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trip.name).font(.headline).foregroundStyle(Theme.ink)
                                if trip.syncTripID.isEmpty {
                                    Text("Only on this phone").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                                    Button("Send to the website") { Task { await upload(trip) } }
                                        .disabled(sync.busy)
                                        .frame(minHeight: 44, alignment: .leading)
                                } else {
                                    Text(trip.syncedAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Linked, not synced yet")
                                        .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                                    Button("Stop syncing this trip", role: .destructive) { sync.unlink(trip) }
                                        .frame(minHeight: 44, alignment: .leading)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("On this phone")
                } footer: {
                    Text("Sending creates a copy on the website that stays linked. If you change the same detail in both places, the website's version is kept.")
                }

                Section {
                    Group {
                        if downloadable.isEmpty {
                            Text(loaded ? "Nothing new on the website." : "Loading ...").foregroundStyle(Theme.inkSecondary)
                        }
                        ForEach(downloadable) { remote in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(remote.name).font(.headline).foregroundStyle(Theme.ink)
                                Text("\(remote.startDate) to \(remote.endDate)").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                                Button("Get this trip") { Task { await download(remote) } }
                                    .disabled(sync.busy)
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("On the website")
                }
            }
        }
        .navigationTitle("Website sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func reload() async {
        guard sync.signedIn else { return }
        do { serverTrips = try await sync.serverTrips() } catch { sync.message = error.localizedDescription }
        loaded = true
    }

    private func upload(_ trip: Trip) async {
        await sync.run { try await sync.upload(trip, context: context) }
        await reload()
    }

    private func download(_ remote: SyncService.ServerTrip) async {
        await sync.run { _ = try await sync.download(remote, context: context) }
        await reload()
    }
}

/// Syncs the linked trips when the app comes to the front (at most once a minute).
struct SyncRunner: ViewModifier {
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query private var trips: [Trip]

    func body(content: Content) -> some View {
        content
            .onChange(of: phase) { _, new in
                guard new == .active else { return }
                if let last = sync.lastRun, Date().timeIntervalSince(last) < 60 { return }
                Task { await sync.syncAll(trips, context: context) }
            }
    }
}

extension View {
    func syncsWithWebsite() -> some View { modifier(SyncRunner()) }
}
