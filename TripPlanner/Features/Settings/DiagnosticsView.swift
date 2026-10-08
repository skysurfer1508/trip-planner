import SwiftUI

/// The last failed requests to the free services the app uses, so a problem can be copied and sent in one go.
/// Nothing here leaves the phone unless the traveller copies it.
struct DiagnosticsView: View {
    @State private var entries = Diagnostics.shared.entries
    @State private var copied = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var system: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    private var report: String {
        Diagnostics.shared.report(appVersion: appVersion, system: system)
    }

    var body: some View {
        List {
            Section {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty)
                Button("Clear the list", role: .destructive) {
                    Diagnostics.shared.clear()
                    reload()
                }
                .disabled(entries.isEmpty)
            } footer: {
                Text("Trip Planner \(appVersion) on \(system). A failed request is a lookup that didn't work: no internet, a busy free service, a refused key. Cancelled lookups aren't listed.")
            }

            Section("Failed requests, newest first") {
                if entries.isEmpty {
                    Text("Nothing has failed since the app was opened.")
                        .foregroundStyle(Theme.inkSecondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.service)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Text(entry.message)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        entries = Diagnostics.shared.entries
        copied = false
    }
}
