import SwiftUI

/// API keys. They are stored in the Keychain on this device only.
struct SettingsView: View {
    @Environment(Secrets.self) private var secrets
    @Environment(\.dismiss) private var dismiss

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
                    SecureField("Anthropic API key", text: $secrets.anthropicKey)
                    Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                } header: {
                    Text("Smart import (Claude)")
                } footer: {
                    Text("Optional. Lets Import program read any layout or language. Costs a few cents per document. The document text is sent to Anthropic only when you pick Claude for an import.")
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
            .onChange(of: secrets.anthropicKey) { secrets.persist() }
        }
    }
}
