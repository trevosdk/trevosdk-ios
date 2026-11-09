import Foundation

/// Durable event buffer: at-least-once delivery, persisted between launches.
final class EventQueue: @unchecked Sendable {
    private struct State {
        var queue: [TrevoEvent] = []
        /// The batch being sent. Persisted with the queue until it's delivered, so a kill mid-send loses nothing.
        var inFlight: [TrevoEvent] = []
        /// Until the stored queue is read, the in-memory one is not the device's queue, so
        /// persisting it would destroy the backlog.
        var hydrated = false
        var flush: Task<Void, Never>?
        var persistScheduled = false
    }

    private let state = Locked(State())
    private let url: URL
    private let headers: [String: String]
    private let maxBatchSize: Int
    private let transport: any TrevoTransport
    private let storage: StorageQueue
    private let onError: ErrorHandler

    init(
        url: URL, headers: [String: String], maxBatchSize: Int, transport: any TrevoTransport,
        storage: StorageQueue, onError: @escaping ErrorHandler
    ) {
        self.url = url
        self.headers = headers
        self.maxBatchSize = min(max(1, maxBatchSize), Constants.serverMaxBatchSize)
        self.transport = transport
        self.storage = storage
        self.onError = onError
    }

    var count: Int { state.withLock { $0.queue.count } }

    func hydrate(_ stored: StoredValue) {
        // Left unhydrated after a failed read, so nothing overwrites a backlog that is still there.
        guard !stored.failed else { return }
        var restored: [TrevoEvent] = []
        if let raw = stored.value {
            do {
                restored = try JSONDecoder().decode([TrevoEvent].self, from: Data(raw.utf8))
            } catch {
                onError(TrevoError("Stored Trevo events unusable", cause: error))
            }
        }
        state.withLock { state in
            state.queue = Array((restored + state.queue).suffix(Constants.maxQueueSize))
            state.hydrated = true
        }
    }

    func enqueue(_ event: TrevoEvent) {
        let dropped = state.withLock { state -> Int in
            state.queue.append(event)
            let overflow = state.queue.count - Constants.maxQueueSize
            if overflow > 0 { state.queue.removeFirst(overflow) }
            return max(0, overflow)
        }
        if dropped > 0 {
            onError(TrevoError("Trevo event queue full, dropped \(dropped) oldest event(s)"))
        }
        schedulePersist()
    }

    /// Callers await this before sign-out and teardown, so a flush already running is joined, not skipped.
    func flush() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            if let running = state.flush { return running }
            guard !state.queue.isEmpty else { return nil }
            let task = Task { [self] in
                await drain()
                self.state.withLock { $0.flush = nil }
            }
            state.flush = task
            return task
        }
        await task?.value
    }

    /// Writes the queue as it is when the write runs, so a later persist never loses to an earlier one.
    func persist() {
        storage.perform("Failed to persist events") { [state] storage in
            let snapshot = state.withLock { state -> [TrevoEvent]? in
                state.hydrated ? state.inFlight + state.queue : nil
            }
            guard let snapshot else { return }
            if snapshot.isEmpty {
                try storage.remove(StorageKey.queue)
            } else {
                try storage.write(StorageKey.queue, value: try JSON.encodeString(snapshot))
            }
        }
    }

    private func schedulePersist() {
        let schedule = state.withLock { state -> Bool in
            defer { state.persistScheduled = true }
            return !state.persistScheduled
        }
        guard schedule else { return }
        Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.persistDebounce * 1_000_000_000))
            state.withLock { $0.persistScheduled = false }
            persist()
        }
    }

    private func drain() async {
        defer { persist() }
        while true {
            // Taken out up front: enqueue trims the head at capacity, so removing by position after
            // the await could discard events that were never sent.
            let batch = state.withLock { state -> [TrevoEvent] in
                let size = min(maxBatchSize, state.queue.count)
                state.inFlight = Array(state.queue.prefix(size))
                state.queue.removeFirst(size)
                return state.inFlight
            }
            if batch.isEmpty { return }

            do {
                try await deliver(batch)
                state.withLock { $0.inFlight = [] }
            } catch let error as DeliveryError where !error.retryable {
                state.withLock { $0.inFlight = [] }
                // Drop this batch, then stop: an endpoint that rejects everything would otherwise
                // burn through the whole offline backlog at once.
                onError(TrevoError("Trevo dropped \(batch.count) event(s): \(error.message)"))
                return
            } catch {
                let lost = state.withLock { state -> Int in
                    state.inFlight = []
                    let restored = batch + state.queue
                    state.queue = Array(restored.suffix(Constants.maxQueueSize))
                    return restored.count - state.queue.count
                }
                if lost > 0 {
                    onError(TrevoError("Trevo event queue full, dropped \(lost) undelivered event(s)"))
                }
                onError(TrevoError("Trevo event delivery failed", cause: error))
                return
            }
        }
    }

    private func deliver(_ events: [TrevoEvent]) async throws {
        let body: Data
        do {
            // Stamped at send, not enqueue: ingestion derives the device's clock offset from it to
            // place a days-old queue on a real timeline.
            body = try JSON.encode(Batch(events: events, sentAt: Timestamp.iso(Date())))
        } catch {
            throw DeliveryError(message: "events could not be encoded", retryable: false)
        }
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response = try await transport.send(
            TrevoHTTPRequest(url: url, method: "POST", headers: headers, body: body))
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw DeliveryError(
                message: "ingestion responded \(status)",
                retryable: status == 408 || status == 429 || status >= 500)
        }
    }
}

private struct Batch: Encodable {
    let events: [TrevoEvent]
    let sentAt: String
}

private struct DeliveryError: Error, LocalizedError {
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}
