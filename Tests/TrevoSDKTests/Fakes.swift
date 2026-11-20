import Foundation
import XCTest

@testable import TrevoSDK

final class MemoryStorage: TrevoStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var unreadable: Set<String>

    init(_ values: [String: String] = [:], unreadable: Set<String> = []) {
        self.values = values
        self.unreadable = unreadable
    }

    func read(_ key: String) throws -> String? {
        try locked {
            if unreadable.contains(key) { throw TrevoError("\(key) is locked") }
            return values[key]
        }
    }

    func write(_ key: String, value: String) throws {
        locked { values[key] = value }
    }

    func remove(_ key: String) throws {
        locked { _ = values.removeValue(forKey: key) }
    }

    subscript(key: String) -> String? {
        locked { values[key] }
    }

    func json(_ key: String) -> TrevoValue? {
        self[key].flatMap { try? JSON.decode($0) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class FakeTransport: TrevoTransport, @unchecked Sendable {
    typealias Handler = @Sendable (TrevoHTTPRequest) async throws -> TrevoHTTPResponse

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [TrevoHTTPRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(config: Data = configBody([]), ingest: Int = 202) {
        self.init(FakeTransport.route(config: config, ingest: ingest))
    }

    static func route(config: Data, ingest: Int, etag: String? = nil) -> Handler {
        { request in
            if request.method == "POST" { return TrevoHTTPResponse(statusCode: ingest) }
            return TrevoHTTPResponse(
                statusCode: 200, headers: etag.map { ["ETag": $0] } ?? [:], body: config)
        }
    }

    func respond(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    var requests: [TrevoHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Every event delivered, across batches.
    var sentEvents: [[String: TrevoValue]] {
        requests.filter { $0.method == "POST" }.flatMap { request -> [[String: TrevoValue]] in
            let body = request.body.flatMap { try? JSON.decode($0) }
            return body?.objectValue?["events"]?.arrayValue?.compactMap(\.objectValue) ?? []
        }
    }

    func send(_ request: TrevoHTTPRequest) async throws -> TrevoHTTPResponse {
        let handler: Handler = {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return self.handler
        }()
        return try await handler(request)
    }
}

final class ManualLifecycle: TrevoLifecycle, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable (TrevoAppStatus) -> Void)?

    func subscribe(_ listener: @escaping @Sendable (TrevoAppStatus) -> Void) -> TrevoSubscription {
        lock.lock()
        self.listener = listener
        lock.unlock()
        return TrevoSubscription { [weak self] in
            self?.lock.lock()
            self?.listener = nil
            self?.lock.unlock()
        }
    }

    var isSubscribed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    func send(_ status: TrevoAppStatus) {
        lock.lock()
        let listener = listener
        lock.unlock()
        listener?(status)
    }
}

final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ error: TrevoError) {
        lock.lock()
        messages.append(error.message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

func experimentJSON(
    _ key: String, _ variants: [(String, Int)], params: [String: [String: TrevoValue]] = [:],
    minAppVersion: [String: TrevoValue]? = nil
) -> TrevoValue {
    var object: [String: TrevoValue] = [
        "experimentKey": .string(key),
        "variants": .array(
            variants.map { name, split in
                var variant: [String: TrevoValue] = [
                    "name": .string(name), "trafficSplit": .number(Double(split)),
                ]
                if let values = params[name] { variant["params"] = .object(values) }
                return .object(variant)
            }),
    ]
    if let minAppVersion { object["minAppVersion"] = .object(minAppVersion) }
    return .object(object)
}

func configBody(_ experiments: [TrevoValue]) -> Data {
    try! JSON.encode(TrevoValue.object(["experiments": .array(experiments)]))
}

func storedConfig(_ experiments: [TrevoValue], etag: String? = nil) -> String {
    var envelope: [String: TrevoValue] = ["experiments": .array(experiments)]
    if let etag { envelope["etag"] = .string(etag) }
    return try! JSON.encodeString(TrevoValue.object(envelope))
}

func makeClient(
    storage: MemoryStorage = MemoryStorage(),
    transport: FakeTransport = FakeTransport(),
    lifecycle: ManualLifecycle = ManualLifecycle(),
    appVersion: String? = "2.0.0",
    locale: String? = nil,
    bootstrap: [ExperimentConfig] = [],
    errors: ErrorLog = ErrorLog(),
    pages: MemoryPaywallFiles = MemoryPaywallFiles()
) -> TrevoClient {
    TrevoClient(
        options: TrevoOptions(
            apiKey: "tsk_live_test", appVersion: appVersion, locale: locale, bootstrapConfig: bootstrap,
            storage: storage, transport: transport, lifecycle: lifecycle,
            onError: { errors.record($0) }),
        paywallFiles: pages, paywallDownloads: true)
}

final class MemoryPaywallFiles: PaywallPageFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: Data]

    init(_ pages: [String: Data] = [:]) {
        self.pages = pages
    }

    func read(_ sha256: String) throws -> Data? {
        locked { pages[sha256] }
    }

    func write(_ sha256: String, _ data: Data) throws {
        locked { pages[sha256] = data }
    }

    func remove(_ sha256: String) throws {
        locked { _ = pages.removeValue(forKey: sha256) }
    }

    func stored() throws -> Set<String> {
        locked { Set(pages.keys) }
    }

    subscript(sha256: String) -> Data? {
        get { locked { pages[sha256] } }
        set { locked { pages[sha256] = newValue } }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Polls until `condition` holds, for effects that land on a background queue.
func waitUntil(
    _ description: String, timeout: TimeInterval = 3, file: StaticString = #filePath,
    line: UInt = #line, _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// An identity whose bucket for `key` lands on the variant at `index` of a 50/50 split.
func identity(bucketing key: String, toward index: Int) -> String {
    (0..<10_000).lazy.map { "user-\($0)" }.first { candidate in
        let bucket = Assignment.bucket(candidate, key)
        return index == 0 ? bucket < 5000 : bucket >= 5000
    }!
}
