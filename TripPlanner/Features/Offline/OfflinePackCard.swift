import SwiftUI

/// Overview card: "Prepare for offline" with progress, and when it was last done.
struct OfflinePackCard: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @State private var runner = OfflinePackRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Ready for offline", systemImage: "arrow.down.circle")
                .font(.headline)

            if runner.running {
                ProgressView(value: runner.progress)
                Text(runner.current.isEmpty ? "Starting…" : runner.current)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                HStack {
                    Text("\(runner.done) of \(runner.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Button("Stop") { runner.cancel() }
                        .font(.footnote.bold())
                }
            } else {
                if let prepared = trip.offlinePreparedAt {
                    Label("Prepared \(prepared.formatted(.relative(presentation: .named)))",
                          systemImage: runner.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(runner.failed == 0 ? Theme.success : Theme.warning)
                    if !trip.offlineNote.isEmpty {
                        Text(trip.offlineNote)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                } else {
                    Text("Save what this trip needs, so it still works without internet abroad.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Button {
                    runner.start(trip: trip, geminiKey: secrets.keys.gemini)
                } label: {
                    Label(trip.offlinePreparedAt == nil ? "Prepare for offline" : "Update",
                          systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Saves routes between your stops, station entrances, photos, descriptions, opening hours, practical information and the transport guide on this iPhone. Live departure times, weather and Apple Maps' own maps need a connection: download the area in Maps (profile picture → Offline Maps) before you fly.")
                .font(.caption2)
                .foregroundStyle(Theme.inkSecondary)
        }
        .card()
    }
}
