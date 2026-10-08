import SwiftUI
import SwiftData

/// API keys. They are stored in the Keychain on this device only.
struct SettingsView: View {
    @Environment(Secrets.self) private var secrets
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @State private var backupURL: URL?
    @State private var showRestore = false
    @State private var restoreMessage: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AIMode.storageKey) private var aiModeRaw = AIMode.automatic.rawValue
    @AppStorage(TransitRouter.settingsKey) private var transitRoutes = true
    @State private var testingGemini = false
    @State private var geminiResult: GeminiCheck?

    var body: some View {
        @Bindable var secrets = secrets

        NavigationStack {
            Form {
                Section {
                    SecureField("OpenTripMap key", text: $secrets.openTripMapKey)
                    Link("Get a free key", destination: URL(string: "https://opentripmap.io/product")!)
                } header: {
                    Text("Popular sights (OpenTripMap)")
                } footer: {
                    Text("Powers the Discover tab: attractions ranked by popularity. Free, no card needed.")
                }

                Section {
                    SecureField("Tripadvisor key", text: $secrets.tripadvisorKey)
                    Link("Tripadvisor Content API", destination: URL(string: "https://www.tripadvisor.com/developers")!)
                } header: {
                    Text("Ratings (Tripadvisor)")
                } footer: {
                    Text("Adds ratings, review counts and rankings to Discover and to the Top rated view in I'm hungry. Has a free monthly allowance; results show Tripadvisor attribution.")
                }

                Section {
                    Toggle("Public transport routes", isOn: $transitRoutes)
                } header: {
                    Text("Public transport")
                } footer: {
                    Text("Routes between stops come from Transitous (transitous.org), a free community service built on the official timetables of many countries, strongest in Europe and parts of North America. Each route is asked for once and then saved on this iPhone. How tickets and passes work comes from Wikivoyage. Times are scheduled times without live delays.")
                }

                Section {
                    SecureField("RapidAPI key for AeroDataBox", text: $secrets.aerodataboxKey)
                    Link("Get the free plan on RapidAPI", destination: URL(string: "https://rapidapi.com/aedbx-aedbx/api/aerodatabox")!)
                } header: {
                    Text("Flight lookup (AeroDataBox)")
                } footer: {
                    Text("Optional. Type a flight number and date and the app fills in the airports and times. Create a free RapidAPI account, subscribe to the Basic (free) plan of AeroDataBox and paste your key here. The free plan allows a few hundred lookups a month. RapidAPI may ask for a card to sign up; the free plan isn't charged.")
                }

                Section {
                    Picker("AI engine", selection: $aiModeRaw) {
                        ForEach(AIMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Label(AIRouter.onDeviceAvailable
                          ? "Apple Intelligence is available on this iPhone."
                          : "Apple Intelligence isn't available here (needs iOS 26 and a supported iPhone with Apple Intelligence turned on).",
                          systemImage: AIRouter.onDeviceAvailable ? "checkmark.seal.fill" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(AIRouter.onDeviceAvailable ? Theme.success : Theme.inkSecondary)
                    SecureField("Gemini API key (optional)", text: $secrets.geminiKey)
                    Link("Get a free Gemini key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    Button {
                        Task { await testGemini() }
                    } label: {
                        HStack {
                            Label("Test Gemini key", systemImage: "checkmark.shield")
                            Spacer()
                            if testingGemini { ProgressView() }
                        }
                    }
                    .disabled(secrets.keys.gemini.isEmpty || testingGemini)
                    if let geminiResult {
                        Label(geminiResult.message,
                              systemImage: geminiResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(geminiResult.ok ? Theme.success : Theme.danger)
                    }
                } header: {
                    Text("AI (import, trip planner, tips)")
                } footer: {
                    Text("Automatic uses Apple Intelligence on the phone when it can (free, private, offline). Otherwise it uses Gemini if you add a key. Gemini's free tier is free of charge, but Google may use free-tier prompts to improve its products, so documents are only sent to Gemini when it is the engine in use. Turn the engine off to keep everything on the phone.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Shows the last lookups that failed (public transport, opening hours, AI...) so a problem is easy to report.")
                }

                Section {
                    if trips.isEmpty {
                        Text("No trips to back up yet.")
                            .foregroundStyle(Theme.inkSecondary)
                    } else if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("Back up all trips", systemImage: "externaldrive.badge.plus")
                        }
                    } else {
                        ProgressView()
                    }
                    Button {
                        showRestore = true
                    } label: {
                        Label("Restore from a trip file", systemImage: "square.and.arrow.down")
                    }
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Trips are stored only on this iPhone. Reinstalling an app that was signed with a free Apple account, or deleting it, erases them, so save a backup to Files or iCloud Drive now and then. Restoring adds copies; it never overwrites existing trips.")
                }

                Section {
                    Text("Keys never leave this iPhone except in requests to the service they belong to.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: trips.count) {
                backupURL = trips.isEmpty ? nil : try? TripArchiver.writeFile(for: trips, includeDocuments: true,
                                                                              name: "Trip Planner backup")
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.tripPlanner, .json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let added = try TripArchiver.importFile(at: url, into: context)
                        restoreMessage = "Added \(added.count) \(added.count == 1 ? "trip" : "trips")."
                    } catch {
                        restoreMessage = error.localizedDescription
                    }
                case .failure(let error):
                    restoreMessage = error.localizedDescription
                }
            }
            .onChange(of: secrets.openTripMapKey) { secrets.persist() }
            .onChange(of: secrets.tripadvisorKey) { secrets.persist() }
            .onChange(of: secrets.geminiKey) {
                secrets.persist()
                geminiResult = nil
            }
            .onChange(of: secrets.aerodataboxKey) { secrets.persist() }
        }
    }

    /// Asks Gemini a one-word question with the key typed above, whatever AI engine is chosen.
    private func testGemini() async {
        testingGemini = true
        geminiResult = nil
        defer { testingGemini = false }
        geminiResult = await GeminiAI(apiKey: secrets.keys.gemini).check()
    }
}
