import SwiftUI

/// The next departures from one stop, all lines, live where the agency shares live data.
struct DepartureBoardView: View {
    let stopId: String
    let stopName: String
    /// The line the traveller is taking: shown highlighted.
    var highlightLine: String?
    let zone: TimeZone

    @Environment(\.dismiss) private var dismiss
    @State private var departures: [TransitLive.Departure] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var updated: Date?

    var body: some View {
        NavigationStack {
            List {
                if let failure, departures.isEmpty {
                    Section {
                        Label(failure, systemImage: "wifi.slash")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                    }
                }
                Section {
                    ForEach(departures) { departure in
                        row(departure)
                    }
                } header: {
                    if let updated {
                        Text("Updated \(TransitTime.timeText(updated, in: zone))")
                            .textCase(nil)
                    }
                } footer: {
                    Text("Live times appear where the transit agency shares them. The list refreshes by itself every 45 seconds; pull down to refresh now. Data: Transitous.")
                }
            }
            .overlay {
                if loading && departures.isEmpty {
                    ProgressView()
                } else if !loading && departures.isEmpty && failure == nil {
                    ContentUnavailableView("No departures", systemImage: "clock.badge.questionmark",
                                           description: Text("Nothing is listed for this stop in the next hours."))
                }
            }
            .refreshable { await load() }
            .navigationTitle(stopName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(45))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ departure: TransitLive.Departure) -> some View {
        let chosen = highlightLine != nil && departure.line == highlightLine
        return HStack(spacing: Spacing.m) {
            badge(departure)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.headsign.map { "towards \($0)" } ?? departure.mode.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if departure.cancelled {
                    Label("Cancelled", systemImage: "xmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.danger)
                } else if departure.realTime {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                } else {
                    Text("Timetable")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                LiveTime(date: departure.departure, delay: departure.delayMinutes, cancelled: departure.cancelled, zone: zone)
                    .font(.body.monospacedDigit().weight(.semibold))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TransitLive.countdownText(until: departure.departure, now: context.date))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(chosen ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func badge(_ departure: TransitLive.Departure) -> some View {
        let color = departure.colorHex.flatMap { Color(hex: $0) } ?? .accentColor
        return HStack(spacing: Spacing.xs) {
            Image(systemName: departure.mode.symbol)
            Text(departure.line ?? departure.mode.title)
                .lineLimit(1)
        }
        .font(.caption.bold())
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(color, in: Radius.shape(Radius.small))
        .foregroundStyle(.white)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await TransitLive.departures(stopId: stopId, from: Date().addingTimeInterval(-120), count: 12)
            if Task.isCancelled { return }
            departures = list
            failure = nil
            updated = Date()
        } catch {
            if Task.isCancelled { return }
            failure = error.localizedDescription
        }
    }
}
