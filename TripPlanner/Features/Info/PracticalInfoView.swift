import SwiftUI

/// Emergency numbers and the practical things to know before and during a trip: money, internet,
/// electricity, safety, manners. Facts come from Wikidata, advice from Wikivoyage.
struct PracticalInfoView: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @State private var loading = false
    @State private var showOriginal = false

    private var info: PracticalInfo? { PracticalInfo.decode(trip.practicalInfo) }
    private var country: String {
        trip.countryName.isEmpty ? (TransitGuide.parts(of: trip.destination).country ?? trip.destination) : trip.countryName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let info {
                    emergency(info)
                    facts(info)
                    notes(info)
                    original(info)
                    sources
                } else if loading {
                    HStack(spacing: Spacing.m) {
                        ProgressView()
                        Text("Loading information about \(country)…")
                            .foregroundStyle(.secondary)
                    }
                    .card()
                } else {
                    ContentUnavailableView {
                        Label("No information yet", systemImage: "info.circle")
                    } description: {
                        Text(trip.destination.isEmpty
                             ? "Set the trip's destination first."
                             : "Couldn't load information for this destination. Check your connection and try again.")
                    } actions: {
                        Button("Try again") { Task { await load(force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(country.isEmpty ? "Practical info" : country)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await load(force: true) }
                }
                .disabled(loading)
            }
        }
        .task { await load(force: false) }
    }

    // MARK: Pieces

    @ViewBuilder
    private func emergency(_ info: PracticalInfo) -> some View {
        let numbers = info.emergencyNumbers
        let lines = info.notes?.emergency ?? []
        if !numbers.isEmpty || !lines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label("Emergency", systemImage: "cross.case.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(numbers, id: \.self) { number in
                    if let url = URL(string: "tel:" + number.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) {
                            Label("Call \(number)", systemImage: "phone.fill")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                }
                Text("Check the official numbers of your embassy and insurer before you leave.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
    }

    @ViewBuilder
    private func facts(_ info: PracticalInfo) -> some View {
        let rows: [(String, String, String)] = [
            ("Currency", "banknote", info.facts?.currency.joined(separator: ", ") ?? ""),
            ("Calling code", "phone", info.facts?.callingCode ?? ""),
            ("Mains voltage", "bolt", info.facts?.voltage.map { "\($0) V" } ?? ""),
            ("Drives on the", "car", info.facts?.drivingSide ?? ""),
        ].filter { !$0.2.isEmpty }

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Label(row.0, systemImage: row.1)
                            .font(.subheadline)
                        Spacer()
                        Text(row.2)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func notes(_ info: PracticalInfo) -> some View {
        if let notes = info.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.l) {
                noteList("Safety", "exclamationmark.shield", notes.safety)
                noteList("Money and tipping", "creditcard", notes.money)
                noteList("Phone and internet", "antenna.radiowaves.left.and.right", notes.connectivity)
                noteList("Electricity", "powerplug", notes.electricity)
                noteList("Health", "heart.text.square", notes.health)
                noteList("Manners", "hand.wave", notes.etiquette)
            }
            .card()
        } else if info.facts != nil && !info.guideText.isEmpty && AIRouter.current(geminiKey: secrets.keys.gemini) == nil {
            Label("Turn on an AI engine in Settings for short notes on safety, money and internet. The original text is below.",
                  systemImage: "wand.and.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func noteList(_ title: String, _ symbol: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.bold())
                ForEach(items, id: \.self) { item in
                    Text("• " + item)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func original(_ info: PracticalInfo) -> some View {
        if !info.guideText.isEmpty {
            DisclosureGroup("Original text from Wikivoyage", isExpanded: $showOriginal) {
                Text(info.guideText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.s)
            }
            .card()
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Facts: Wikidata (CC0). Advice: Wikivoyage (CC BY-SA), summarised by the AI from that text only. It can be out of date, so check official sources for entry rules, health and safety.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let url = URL(string: "https://en.wikivoyage.org/wiki/\(country.replacingOccurrences(of: " ", with: "_"))") {
                Link("Read more on Wikivoyage", destination: url)
                    .font(.caption2)
            }
        }
    }

    private func load(force: Bool) async {
        guard !trip.destination.isEmpty else { return }
        loading = info == nil || force
        await PracticalInfoService.ensure(for: trip, geminiKey: secrets.keys.gemini, force: force)
        loading = false
    }
}

/// A short card on the Overview: emergency number first, then a way into the details.
struct PracticalInfoCard: View {
    @Bindable var trip: Trip
    @Environment(Secrets.self) private var secrets

    var body: some View {
        let info = PracticalInfo.decode(trip.practicalInfo)

        NavigationLink {
            PracticalInfoView(trip: trip)
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Practical info" + (trip.countryName.isEmpty ? "" : " · \(trip.countryName)"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(summary(info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .task(id: trip.destination) {
            guard !trip.destination.isEmpty else { return }
            await PracticalInfoService.ensure(for: trip, geminiKey: secrets.keys.gemini)
        }
    }

    private func summary(_ info: PracticalInfo?) -> String {
        guard let info else { return "Emergency numbers, money, internet, safety" }
        if let number = info.emergencyNumbers.first { return "Emergency \(number) · money, internet, safety" }
        return "Money, internet, electricity, safety"
    }
}
