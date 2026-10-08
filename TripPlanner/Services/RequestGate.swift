import Foundation

/// Lets a few requests run at once with a pause between them, for services that ask for light use.
/// Waiting tasks leave the queue as soon as they are cancelled (scrolling a list away cancels its lookups),
/// instead of spinning until a slot frees up.
actor RequestGate {
    private let limit: Int
    private let minGap: TimeInterval
    private var active = 0
    private var lastStart = Date.distantPast
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int, minGap: TimeInterval = 0) {
        self.limit = limit
        self.minGap = minGap
    }

    /// Waits for a free slot. Throws `CancellationError` if the task is cancelled while waiting.
    /// Every successful call must be followed by `leave()`.
    func enter() async throws {
        if active < limit && waiters.isEmpty {
            active += 1
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        do {
            try await spaceOut()
        } catch {
            leave()
            throw error
        }
    }

    func leave() {
        active -= 1
        while active < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            active += 1
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func spaceOut() async throws {
        let wait = minGap - Date().timeIntervalSince(lastStart)
        lastStart = Date().addingTimeInterval(max(wait, 0))
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
    }
}

/// Apple Maps limits how many searches and directions an app may ask for (about 50 a minute). Everything
/// that uses MapKit asks here first, so a long list or a big plan slows down instead of failing.
actor MapKitThrottle {
    static let shared = MapKitThrottle(perMinute: 40)

    private let perMinute: Int
    private var starts: [Date] = []

    init(perMinute: Int) {
        self.perMinute = perMinute
    }

    /// Waits until a call is allowed. False if the task was cancelled while waiting.
    func acquire() async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let now = Date()
            starts.removeAll { now.timeIntervalSince($0) >= 60 }
            if starts.count < perMinute {
                starts.append(now)
                return true
            }
            let wait = 60 - now.timeIntervalSince(starts[0]) + 0.05
            try? await Task.sleep(for: .milliseconds(Int(max(wait, 0.1) * 1000)))
        }
    }
}
