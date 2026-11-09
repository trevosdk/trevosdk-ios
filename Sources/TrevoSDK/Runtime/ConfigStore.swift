import Foundation

/// Experiment config, persisted between launches. Persistence is not an optimisation: a client
/// that starts empty serves control all session, then silently switches.
final class ConfigStore: @unchecked Sendable {
    private struct State {
        var registry = ExperimentRegistry()
        var etag: String?
        var hasConfig = false
        var refresh: Task<Void, Never>?
    }

    private let state = Locked(State())
    private let url: URL
    private let headers: [String: String]
    private let transport: any TrevoTransport
    private let storage: StorageQueue
    private let onError: ErrorHandler
    private let onChange: @Sendable () -> Void

    init(
        url: URL, headers: [String: String], transport: any TrevoTransport, storage: StorageQueue,
        onError: @escaping ErrorHandler, onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.headers = headers
        self.transport = transport
        self.storage = storage
        self.onError = onError
        self.onChange = onChange
    }

    /// True once storage or the network has supplied a config, which then replaces any bootstrap.
    var hasConfig: Bool { state.withLock { $0.hasConfig } }

    var all: [ExperimentConfig] { state.withLock { $0.registry.all } }

    func experiment(_ key: String) -> ExperimentConfig? {
        state.withLock { $0.registry[key] }
    }

    /// Adopts the config stored by an earlier launch, unless a fetched one already landed.
    func hydrate(_ stored: StoredValue) {
        guard let raw = stored.value else { return }
        guard let envelope = try? JSON.decode(raw).objectValue,
            case .success(let experiments) = ConfigParser.parse(.object(envelope))
        else {
            // A blob from an older build or a torn write would otherwise be retried every launch.
            onError(TrevoError("Stored Trevo config unusable"))
            storage.remove(StorageKey.config, failure: "Failed to clear stored config")
            return
        }
        let adopted = state.withLock { state -> Bool in
            guard !state.hasConfig else { return false }
            state.registry = ExperimentRegistry(experiments)
            state.etag = envelope["etag"]?.stringValue
            state.hasConfig = true
            return true
        }
        if adopted { onChange() }
    }

    /// One fetch at a time, so an older response can never replace a newer one. A failure keeps
    /// the last-known config: on a phone the network is usually just absent.
    func refresh() async {
        let task = state.withLock { state -> Task<Void, Never> in
            if let running = state.refresh { return running }
            let task = Task { [self] in
                await fetch()
                self.state.withLock { $0.refresh = nil }
            }
            state.refresh = task
            return task
        }
        await task.value
    }

    private func fetch() async {
        var headers = headers
        headers["Accept"] = "application/json"
        if let etag = state.withLock({ $0.etag }) { headers["If-None-Match"] = etag }

        let response: TrevoHTTPResponse
        do {
            response = try await transport.send(
                TrevoHTTPRequest(url: url, method: "GET", headers: headers))
        } catch {
            onError(TrevoError("Trevo config refresh failed", cause: error))
            return
        }

        if response.statusCode == 304 { return }
        guard (200..<300).contains(response.statusCode) else {
            onError(TrevoError("Trevo config fetch failed with \(response.statusCode)"))
            return
        }

        let body: TrevoValue
        do {
            body = try JSON.decode(response.body)
        } catch {
            onError(TrevoError("Trevo config response is not JSON", cause: error))
            return
        }
        let experiments: [ExperimentConfig]
        switch ConfigParser.parse(body) {
        case .success(let parsed):
            experiments = parsed
        case .failure(let error):
            // Adopting it would break every assignment until the next poll.
            onError(TrevoError("Trevo config response invalid: \(error.message)"))
            return
        }

        // Cleared when the response carries none: a stale validator pins the client to old config.
        let etag = response.headers["etag"]
        state.withLock { state in
            state.registry = ExperimentRegistry(experiments)
            state.etag = etag
            state.hasConfig = true
        }
        onChange()
        persist(experiments: body.objectValue?["experiments"] ?? .array([]), etag: etag)
    }

    private func persist(experiments: TrevoValue, etag: String?) {
        var envelope: [String: TrevoValue] = ["experiments": experiments]
        if let etag { envelope["etag"] = .string(etag) }
        do {
            let raw = try JSON.encodeString(TrevoValue.object(envelope))
            storage.write(StorageKey.config, raw, failure: "Failed to persist config")
        } catch {
            onError(TrevoError("Failed to encode config", cause: error))
        }
    }
}
