import SwiftUI
import SwiftData

/// Talk to the AI about the plan: "move the museum to day 2", "make day 3 more relaxed", "start
/// everything an hour later". The AI can only use the stops in the plan and real places nearby.
/// Every change can be undone.
struct PlanChatView: View {
    @Bindable var trip: Trip

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    private struct Message: Identifiable {
        enum Role { case traveller, assistant, problem }
        let id = UUID()
        var role: Role
        var text: String
        var changes: [String] = []
    }

    private static let suggestions = [
        "Start everything an hour later",
        "Swap day 1 and day 2",
        "Put the museums in the morning",
        "Add a coffee break on day 1",
        "Make the last day more relaxed",
        "Remove the last stop of every day",
        "Adjust all the times",
    ]

    @State private var messages: [Message] = []
    @State private var prompt = ""
    @State private var busy = false
    @State private var pool: [PlanCandidate] = []
    @State private var undoStack: [TripSnapshot] = []
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var engine: (any AIEngine)? { AIRouter.current(geminiKey: secrets.keys.gemini) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            intro
                            ForEach(messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                            if busy {
                                HStack(spacing: Spacing.s) {
                                    ProgressView()
                                    Text("Thinking…").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                composer
            }
            .navigationTitle("Ask the AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                        .disabled(undoStack.isEmpty || busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPool() }
            .onDisappear { sendTask?.cancel() }
        }
        .presentationDetents([.large])
    }

    // MARK: Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Tell me what to change in the plan.", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Text("I can move places between days, change times, swap days, add places nearby or remove some. I only use places that are really there, and you can undo every change.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if engine == nil {
                Label("Turn on an AI engine in Settings to type your own requests.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(message.text)
                .font(.subheadline)
            ForEach(message.changes, id: \.self) { change in
                Label(change, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: message.role == .traveller ? .trailing : .leading)
        .background(background(for: message.role), in: Radius.shape(Radius.card))
        .padding(.leading, message.role == .traveller ? 40 : 0)
        .padding(.trailing, message.role == .traveller ? 0 : 40)
    }

    private func background(for role: Message.Role) -> Color {
        switch role {
        case .traveller: Color.accentColor.opacity(0.18)
        case .assistant: Color(.secondarySystemBackground)
        case .problem: Color.orange.opacity(0.15)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            prompt = suggestion
                            focused = true
                        } label: {
                            Text(suggestion)
                                .font(.footnote)
                                .padding(.horizontal, Spacing.m)
                                .padding(.vertical, Spacing.s)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Spacing.s) {
                TextField(engine == nil ? "No AI engine turned on" : "What should change?", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(engine == nil || busy)
                    .submitLabel(.send)
                    .onSubmit { start() }
                Button {
                    start()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(engine == nil || busy || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, Spacing.m)
        .background(.bar)
    }

    // MARK: Actions

    /// A few real places of each kind near the destination, so "add a coffee break" has something to use.
    private func loadPool() async {
        guard pool.isEmpty, let center = trip.destinationCoordinate ?? trip.anyCoordinate else { return }
        var places: [PlanCandidate] = []
        for kind in [DiscoverKind.sights, .food, .cafe, .culture] {
            let keys = (kind == .sights || kind == .food)
                ? secrets.keys
                : APIKeys(openTripMap: secrets.keys.openTripMap, tripadvisor: "", gemini: "")
            let result = await SuggestionService.load(kind: kind, center: center, radiusMeters: 8_000, keys: keys)
            places += result.places.map(AutoPlanService.candidate(from:))
        }
        pool = AutoPlanner.dedupe(places)
    }

    /// The request runs in a task of its own that is cancelled when the sheet closes, so nothing
    /// changes the plan after the traveller has left (and can no longer undo it).
    private func start() {
        sendTask = Task { await send() }
    }

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !text.isEmpty, !busy else { return }
        prompt = ""
        messages.append(Message(role: .traveller, text: text))
        busy = true
        defer { busy = false }

        let prepared = PlanChatService.prepare(instruction: text, trip: trip, pool: pool)
        do {
            let response = try await engine.editPlan(prepared.request)
            guard !Task.isCancelled else { return }
            guard !response.commands.isEmpty else {
                messages.append(Message(role: .assistant,
                                        text: response.summary.isEmpty ? "I couldn't find a way to do that with this plan." : response.summary))
                return
            }
            let snapshot = TripSnapshot.capture(trip)
            let outcome = PlanChatApplier.apply(response.commands, trip: trip,
                                                stops: prepared.stops, places: prepared.places)
            if outcome.changed {
                undoStack.append(snapshot)
                if undoStack.count > 10 { undoStack.removeFirst() }
                var reply = response.summary
                if !outcome.notes.isEmpty {
                    reply += (reply.isEmpty ? "" : " ") + outcome.notes.joined(separator: " ")
                }
                messages.append(Message(role: .assistant, text: reply.isEmpty ? "Done." : reply, changes: outcome.changes))
            } else {
                let reason = outcome.notes.first ?? "Nothing changed."
                messages.append(Message(role: .problem, text: reason))
            }
        } catch {
            messages.append(Message(role: .problem, text: error.localizedDescription))
        }
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        snapshot.restore(into: trip)
        messages.append(Message(role: .assistant, text: "Undone."))
    }
}
