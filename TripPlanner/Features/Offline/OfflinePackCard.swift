import SwiftUI

/// Overview card: "Prepare for offline" with progress, and when it was last done.
struct OfflinePackCard: View {
    @Bindable var trip: Trip

    @Environment(Secrets.self) private var secrets
    @State private var runner = OfflinePackRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready for offline", systemImage: "arrow.down.circle")
                .font(.headline)

            if runner.running {
                ProgressView(value: runner.progress)
                Text(runner.current.isEmpty ? "Starting…" : runner.current)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Text("\(runner.done) of \(runner.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { runner.cancel() }
                        .font(.footnote.bold())
                }
            } else {
                if let prepared = trip.offlinePreparedAt {
                    Label("Prepared \(prepared.formatted(.relative(presentation: .named)))",
                          systemImage: runner.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(runner.failed == 0 ? Color.green : Color.orange)
                    if !trip.offlineNote.isEmpty {
                        Text(trip.offlineNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Save what this trip needs, so it still works without internet abroad.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }
        .card()
    }
}
