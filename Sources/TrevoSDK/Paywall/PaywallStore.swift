import CryptoKit
import Foundation

enum PaywallFallbackReason: String, Sendable, CaseIterable {
    case notDownloaded = "not_downloaded"
    case unsupported
    case skipped
    case timeout
    case crashed
    /// React Native only: iOS blocks navigation outright.
    case navigated
    case noWebView = "no_webview"
}

/// Which pages are held for each id (the current first, then the one before) and how often each
/// version failed to show. Persisted as JSON under `StorageKey.paywalls`.
struct PaywallIndex: Equatable {
    var pages: [String: [String]] = [:]
    var failures: [String: Int] = [:]

    var held: Set<String> { Set(pages.values.joined()) }

    mutating func promote(_ sha256: String, for id: String) {
        pages[id] = Array(([sha256] + (pages[id] ?? []).filter { $0 != sha256 }).prefix(2))
    }

    mutating func drop(_ sha256: String) {
        pages = pages.mapValues { $0.filter { $0 != sha256 } }.filter { !$0.value.isEmpty }
    }

    var json: TrevoValue {
        .object([
            "pages": .object(pages.mapValues { .array($0.map(TrevoValue.string)) }),
            "failures": .object(failures.mapValues { .number(Double($0)) }),
        ])
    }

    init() {}

    init?(_ value: TrevoValue) {
        guard let object = value.objectValue,
            let pages = object["pages"]?.objectValue,
            let failures = object["failures"]?.objectValue
        else { return nil }
        self.pages = pages.compactMapValues { $0.arrayValue?.compactMap(\.stringValue) }
        self.failures = failures.compactMapValues { $0.numberValue.flatMap { Int(exactly: $0) } }
    }
}

/// Downloads, verifies and keeps the pages config names, and decides what the view shows.
/// Spec: docs/sdk/remote-paywall.md, section 5.
final class PaywallStore: @unchecked Sendable {
    enum Choice: Equatable {
        /// Config names no page for the id: the app's own paywall, nothing reported.
        case off
        case fallback(PaywallFallbackReason, sha256: String)
        case show(PaywallConfigEntry, html: String)
    }

    static let maxFailures = 2

    private struct State {
        var entries: [PaywallConfigEntry] = []
        var index = PaywallIndex()
        var downloading: String?
        var downloader: Task<Void, Never>?
        // Cleared when a round ends, so the next round tries network failures again.
        var attempted: Set<String> = []
        // Arrived but failed its checks: not fetched again until the next launch.
        var rejected: Set<String> = []
        var reportedIds: Set<String> = []
        var stopped = false
    }

    private let state = Locked(State())
    private let files: any PaywallPageFiles
    private let transport: any TrevoTransport
    private let storage: StorageQueue
    private let onError: ErrorHandler
    private let sdkVersion: String
    private let downloads: Bool
    // Every write and removal of a page runs here, so pruning never races a download.
    private let io = DispatchQueue(label: "com.trevosdk.paywalls", qos: .utility)

    init(
        files: any PaywallPageFiles, transport: any TrevoTransport, storage: StorageQueue,
        onError: @escaping ErrorHandler, sdkVersion: String = TrevoSDKVersion.current,
        downloads: Bool = PaywallStore.platformHasView
    ) {
        self.files = files
        self.transport = transport
        self.storage = storage
        self.onError = onError
        self.sdkVersion = sdkVersion
        self.downloads = downloads
    }

    // Only iOS has the view, so other platforms never fetch a page they can't show.
    #if os(iOS)
        static let platformHasView = true
    #else
        static let platformHasView = false
    #endif

    func hydrate(_ stored: StoredValue) {
        guard let raw = stored.value else { return }
        guard let value = try? JSON.decode(raw), let index = PaywallIndex(value) else {
            onError(TrevoError("Stored paywall index unusable"))
            storage.remove(StorageKey.paywalls, failure: "Failed to clear stored paywall index")
            return
        }
        state.withLock { $0.index = index }
    }

    /// The paywalls of a config the client adopted. After a fetched one, ids it no longer names lose
    /// their pages.
    func adopt(_ entries: [PaywallConfigEntry], fetched: Bool) {
        let changed = state.withLock { state -> Bool in
            state.entries = entries
            let before = state.index
            if fetched {
                let named = Set(entries.map(\.id))
                state.index.pages = state.index.pages.filter { named.contains($0.key) }
            }
            // Naming a held page again makes it current, so a revert keeps the right pair. A page
            // another id holds counts too, or removing that id would delete it.
            let held = state.index.held
            for entry in entries where held.contains(entry.sha256) {
                state.index.promote(entry.sha256, for: entry.id)
            }
            return state.index != before
        }
        if changed {
            persistIndex()
            io.async { [self] in prune() }
        }
        downloadMissing()
    }

    /// Fetches, one at a time, every page config names that this build can show and doesn't hold.
    func downloadMissing() {
        guard downloads else { return }
        state.withLock { state in
            guard state.downloader == nil, !state.stopped else { return }
            state.downloader = Task { [weak self] in
                while let entry = self?.nextDownload() {
                    await self?.download(entry)
                }
            }
        }
    }

    /// What the view shows for `id`, with the stored copy's hash checked again.
    func choose(_ id: String) -> Choice {
        let found = state.withLock { state in
            state.entries.first { $0.id == id }.map {
                ($0, state.index.failures[$0.sha256] ?? 0, state.index.held.contains($0.sha256))
            }
        }
        guard let (entry, failures, held) = found else { return .off }
        guard PaywallConfig.canShow(entry, sdkVersion: sdkVersion) else {
            return .fallback(.unsupported, sha256: entry.sha256)
        }
        if failures >= Self.maxFailures { return .fallback(.skipped, sha256: entry.sha256) }
        let data: Data?
        do {
            data = try files.read(entry.sha256)
        } catch {
            onError(TrevoError("Failed to read paywall \(entry.id)", cause: error))
            data = nil
        }
        guard let data, Self.sha256(data) == entry.sha256 else {
            if data != nil { onError(TrevoError("Stored paywall \(entry.id) failed its hash check")) }
            if data != nil || held { discard(entry.sha256) }
            downloadMissing()
            return .fallback(.notDownloaded, sha256: entry.sha256)
        }
        return .show(entry, html: PaywallGuard.guarded(String(decoding: data, as: UTF8.self)))
    }

    /// A timeout after the page started. Two skip the version on this device.
    func recordFailure(_ sha256: String) {
        state.withLock { $0.index.failures[sha256, default: 0] += 1 }
        persistIndex()
    }

    /// True the first time `id` is seen, so a bad id is reported once per launch.
    func firstReport(of id: String) -> Bool {
        state.withLock { $0.reportedIds.insert(id).inserted }
    }

    /// Shutdown: no new download starts, and a running one keeps nothing.
    func stop() {
        let downloader = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            return state.downloader
        }
        downloader?.cancel()
    }

    /// Resolves once no download is running and every queued page write has landed.
    func idle() async {
        while let task = state.withLock({ $0.downloader }) { await task.value }
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
    }

    private func nextDownload() -> PaywallConfigEntry? {
        state.withLock { state in
            let held = state.index.held
            let next = state.entries.first {
                PaywallConfig.canShow($0, sdkVersion: sdkVersion) && !held.contains($0.sha256)
                    && !state.attempted.contains($0.sha256) && !state.rejected.contains($0.sha256)
            }
            guard let next, !state.stopped else {
                state.downloader = nil
                state.downloading = nil
                state.attempted = []
                return nil
            }
            state.attempted.insert(next.sha256)
            state.downloading = next.sha256
            return next
        }
    }

    private func download(_ entry: PaywallConfigEntry) async {
        guard let url = URL(string: entry.url) else {
            return onError(TrevoError("Paywall \(entry.id) has an unusable URL"))
        }
        let response: TrevoHTTPResponse
        do {
            // A public file on the CDN: the API key stays with Trevo's own endpoints.
            response = try await transport.send(
                TrevoHTTPRequest(
                    url: url, method: "GET", headers: ["Accept": "text/html"],
                    maxResponseBytes: PaywallConfig.maxDocumentBytes))
        } catch is ResponseTooLong {
            return reject(entry, "is over \(PaywallConfig.maxDocumentBytes) bytes")
        } catch {
            return onError(TrevoError("Paywall \(entry.id) download failed", cause: error))
        }
        guard (200..<300).contains(response.statusCode) else {
            return onError(TrevoError("Paywall \(entry.id) download failed with \(response.statusCode)"))
        }
        // Again here, for a custom transport that ignores the limit.
        guard response.body.count <= PaywallConfig.maxDocumentBytes else {
            return reject(entry, "is over \(PaywallConfig.maxDocumentBytes) bytes")
        }
        guard Self.sha256(response.body) == entry.sha256 else {
            return reject(entry, "doesn't match its SHA-256")
        }
        await withCheckedContinuation { continuation in
            io.async { [self] in
                keep(response.body, as: entry.sha256)
                continuation.resume()
            }
        }
    }

    private func reject(_ entry: PaywallConfigEntry, _ problem: String) {
        state.withLock { _ = $0.rejected.insert(entry.sha256) }
        onError(TrevoError("Paywall \(entry.id) \(problem)"))
    }

    // On `io`. A page config stopped naming while it downloaded is not kept.
    private func keep(_ data: Data, as sha256: String) {
        let ids = state.withLock { state in
            state.stopped ? [] : state.entries.filter { $0.sha256 == sha256 }.map(\.id)
        }
        guard !ids.isEmpty else { return }
        do {
            try files.write(sha256, data)
        } catch {
            return onError(TrevoError("Failed to store paywall \(sha256)", cause: error))
        }
        state.withLock { state in
            for id in ids { state.index.promote(sha256, for: id) }
        }
        persistIndex()
        prune()
    }

    private func discard(_ sha256: String) {
        state.withLock { $0.index.drop(sha256) }
        persistIndex()
        io.async { [self] in
            do {
                try files.remove(sha256)
            } catch {
                onError(TrevoError("Failed to remove paywall \(sha256)", cause: error))
            }
        }
    }

    // On `io`. Removes pages no id holds, and the failure counts of versions no longer held.
    private func prune() {
        let (keep, failuresChanged) = state.withLock { state -> (Set<String>, Bool) in
            var keep = state.index.held
            if let downloading = state.downloading { keep.insert(downloading) }
            let failures = state.index.failures.filter { keep.contains($0.key) }
            defer { state.index.failures = failures }
            return (keep, failures != state.index.failures)
        }
        if failuresChanged { persistIndex() }
        do {
            for sha256 in try files.stored() where !keep.contains(sha256) {
                try files.remove(sha256)
            }
        } catch {
            onError(TrevoError("Failed to prune stored paywalls", cause: error))
        }
    }

    private func persistIndex() {
        storage.perform("Failed to persist paywall index") { [state] storage in
            // Read when the write runs, so a burst of changes ends with the newest snapshot.
            let index = state.withLock { $0.index }
            try storage.write(StorageKey.paywalls, value: try JSON.encodeString(index.json))
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
