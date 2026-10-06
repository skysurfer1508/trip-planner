import SwiftUI

/// API keys. They are stored in the Keychain on this device only.
struct SettingsView: View {
    @Environment(Secrets.self) private var secrets
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AIMode.storageKey) private var aiModeRaw = AIMode.automatic.rawValue

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
                    Picker("AI engine", selection: $aiModeRaw) {
                        ForEach(AIMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Label(AIRouter.onDeviceAvailable
                          ? "Apple Intelligence is available on this iPhone."
                          : "Apple Intelligence isn't available here (needs iOS 26 and a supported iPhone with Apple Intelligence turned on).",
                          systemImage: AIRouter.onDeviceAvailable ? "checkmark.seal.fill" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(AIRouter.onDeviceAvailable ? Color.green : Color.secondary)
                    SecureField("Gemini API key (optional)", text: $secrets.geminiKey)
                    Link("Get a free Gemini key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                } header: {
                    Text("AI (import, trip planner, tips)")
                } footer: {
                    Text("Automatic uses Apple Intelligence on the phone when it can (free, private, offline). Otherwise it uses Gemini if you add a key. Gemini's free tier is free of charge, but Google may use free-tier prompts to improve its products, so documents are only sent to Gemini when it is the engine in use. Turn the engine off to keep everything on the phone.")
                }

                Section {
                    Text("Keys never leave this iPhone except in requests to the service they belong to.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: secrets.openTripMapKey) { secrets.persist() }
            .onChange(of: secrets.tripadvisorKey) { secrets.persist() }
            .onChange(of: secrets.geminiKey) { secrets.persist() }
        }
    }
}
