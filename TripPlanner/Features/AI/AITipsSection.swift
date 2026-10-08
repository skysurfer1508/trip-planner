import SwiftUI

/// Three short AI tips for a place. Hidden when no AI engine is available (unless tips were
/// saved earlier).
struct AITipsSection: View {
    let name: String
    let city: String
    /// Where to keep the tips so they work offline later (e.g. `Stop.aiTips`).
    var cached: Binding<String>?

    @Environment(Secrets.self) private var secrets
    @State private var tips: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        let engine = AIRouter.current(geminiKey: secrets.keys.gemini)

        Group {
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb")
                            .font(.subheadline)
                    }
                    Text("Written by AI. Double-check opening hours and prices.")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSecondary)
                }
            } else if let engine {
                Button {
                    Task { await load(with: engine) }
                } label: {
                    Label(isLoading ? "Asking…" : "Show tips (\(engine.label))", systemImage: "wand.and.stars")
                }
                .disabled(isLoading)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .onAppear {
            if tips.isEmpty, let saved = cached?.wrappedValue, !saved.isEmpty {
                tips = saved.components(separatedBy: "\n")
            }
        }
    }

    private func load(with engine: any AIEngine) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await engine.placeTips(name: name, city: city)
            tips = Array(result.prefix(3))
            cached?.wrappedValue = tips.joined(separator: "\n")
        } catch {
            errorText = error.localizedDescription
        }
    }
}
