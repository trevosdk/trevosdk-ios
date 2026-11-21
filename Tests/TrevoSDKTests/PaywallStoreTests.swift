import Foundation
import XCTest

@testable import TrevoSDK

/// A page the CDN serves, with the entry config would list for it.
struct TestPage {
    let html: String
    let id: String

    init(_ html: String, id: String = "main") {
        self.html = html
        self.id = id
    }

    var data: Data { Data(html.utf8) }
    var sha256: String { PaywallStore.sha256(data) }
    var url: String { "https://cdn.trevosdk.com/paywalls/\(sha256).html" }

    func entry(format: Int = 1, minSdkVersion: [String: TrevoValue]? = nil) -> TrevoValue {
        var object: [String: TrevoValue] = [
            "id": .string(id), "url": .string(url), "sha256": .string(sha256),
            "format": .number(Double(format)), "bridge": 1,
        ]
        if let minSdkVersion { object["minSdkVersion"] = .object(minSdkVersion) }
        return .object(object)
    }

    var parsed: PaywallConfigEntry { PaywallConfig.parse(.array([entry()])).first! }
}

/// Serves config and pages, and counts what each URL was asked for.
func paywallTransport(
    config: @escaping @Sendable () -> TrevoValue, pages: @escaping @Sendable () -> [TestPage]
) -> FakeTransport {
    FakeTransport { request in
        if request.method == "POST" { return TrevoHTTPResponse(statusCode: 202) }
        if request.url.host == "cdn.trevosdk.com" {
            guard let page = pages().first(where: { $0.url == request.url.absoluteString }) else {
                return TrevoHTTPResponse(statusCode: 404)
            }
            return TrevoHTTPResponse(statusCode: 200, body: page.data)
        }
        return TrevoHTTPResponse(statusCode: 200, body: try JSON.encode(config()))
    }
}

func config(_ experiments: [TrevoValue] = [], paywalls: TrevoValue?) -> TrevoValue {
    var object: [String: TrevoValue] = ["experiments": .array(experiments)]
    if let paywalls { object["paywalls"] = paywalls }
    return .object(object)
}

final class PaywallStoreTests: XCTestCase {
    private let a = TestPage("<!doctype html><html><head></head><body>A</body></html>")
    private let b = TestPage("<!doctype html><html><head></head><body>B</body></html>")
    private let c = TestPage("<!doctype html><html><head></head><body>C</body></html>")

    private func store(
        serving pages: [TestPage], files: MemoryPaywallFiles = MemoryPaywallFiles(),
        storage: MemoryStorage = MemoryStorage(), errors: ErrorLog = ErrorLog(),
        transport: FakeTransport? = nil
    ) -> (PaywallStore, FakeTransport) {
        let transport = transport ?? paywallTransport(config: { config(paywalls: nil) }, pages: { pages })
        let onError: ErrorHandler = { errors.record($0) }
        let store = PaywallStore(
            files: files, transport: transport, storage: StorageQueue(storage: storage, onError: onError),
            onError: onError, sdkVersion: "0.2.0", downloads: true)
        return (store, transport)
    }

    private func downloads(_ transport: FakeTransport) -> [String] {
        transport.requests.filter { $0.url.host == "cdn.trevosdk.com" }.map(\.url.absoluteString)
    }

    func testDownloadsTheNamedPageWithoutTheApiKeyAndShowsItGuarded() async {
        let (store, transport) = store(serving: [a])
        store.adopt([a.parsed], fetched: true)
        await store.idle()

        XCTAssertEqual(store.choose("main"), .show(a.parsed, html: PaywallGuard.guarded(a.html)))
        XCTAssertEqual(downloads(transport), [a.url])
        XCTAssertNil(transport.requests.first?.headers["Authorization"])
    }

    // A wrong page would come back wrong on every refresh, so it waits for the next launch.
    func testRefusesBytesThatDontMatchTheHashAndDoesntFetchThemAgain() async {
        let errors = ErrorLog()
        let tampered = FakeTransport { _ in TrevoHTTPResponse(statusCode: 200, body: Data("<p>evil</p>".utf8))
        }
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [], files: files, errors: errors, transport: tampered)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        store.downloadMissing()
        await store.idle()

        XCTAssertEqual(try files.stored(), [])
        XCTAssertEqual(store.choose("main"), .fallback(.notDownloaded, sha256: a.sha256))
        XCTAssertTrue(errors.all.contains { $0.contains("SHA-256") })
        XCTAssertEqual(tampered.requests.count, 1)
    }

    func testAsksTheTransportForTheSizeLimitAndDoesntFetchARefusedBodyAgain() async {
        let transport = FakeTransport { request in
            XCTAssertEqual(request.maxResponseBytes, PaywallConfig.maxDocumentBytes)
            throw ResponseTooLong(limit: PaywallConfig.maxDocumentBytes)
        }
        let (store, _) = store(serving: [], transport: transport)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        store.downloadMissing()
        await store.idle()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(store.choose("main"), .fallback(.notDownloaded, sha256: a.sha256))
    }

    func testRefusesAPageOverTheSizeLimitFromATransportThatIgnoresIt() async {
        let huge = TestPage(String(repeating: "a", count: PaywallConfig.maxDocumentBytes + 1))
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [huge], files: files)
        store.adopt([huge.parsed], fetched: true)
        await store.idle()

        XCTAssertEqual(try files.stored(), [])
    }

    func testAPageTwoIdsShareSurvivesRemovingOneOfThem() async {
        let files = MemoryPaywallFiles()
        let (store, transport) = store(serving: [a], files: files)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        let other = PaywallConfig.parse(.array([TestPage(a.html, id: "other").entry()]))
        store.adopt([a.parsed] + other, fetched: true)
        await store.idle()
        store.adopt(other, fetched: true)
        await store.idle()

        XCTAssertEqual(try files.stored(), [a.sha256])
        XCTAssertEqual(store.choose("other"), .show(other[0], html: PaywallGuard.guarded(a.html)))
        XCTAssertEqual(downloads(transport), [a.url])
    }

    func testOpeningAPageNotDownloadedYetWritesNothing() async {
        let storage = MemoryStorage()
        let (store, _) = store(serving: [], storage: storage)
        store.adopt([a.parsed], fetched: false)
        await store.idle()

        XCTAssertEqual(store.choose("main"), .fallback(.notDownloaded, sha256: a.sha256))
        await store.idle()
        XCTAssertNil(storage[StorageKey.paywalls])
    }

    func testAStoppedStoreKeepsNothingFromADownloadStillRunning() async {
        let release = Locked<CheckedContinuation<Void, Never>?>(nil)
        let transport = FakeTransport { [a] _ in
            await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
            return TrevoHTTPResponse(statusCode: 200, body: a.data)
        }
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [], files: files, transport: transport)
        store.adopt([a.parsed], fetched: true)
        await waitUntil("download started") { release.withLock { $0 != nil } }

        store.stop()
        release.withLock { $0 }?.resume()
        await store.idle()
        XCTAssertEqual(try files.stored(), [])
    }

    func testAStoredFailureCountTooLargeForAnIntIsDropped() {
        let index = PaywallIndex(["pages": [:], "failures": [a.sha256: 1e300, b.sha256: 1]])
        XCTAssertEqual(index?.failures, [b.sha256: 1])
    }

    func testKeepsTheCurrentPageAndTheOneBeforeIt() async {
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [a, b, c], files: files)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        store.adopt([b.parsed], fetched: true)
        await store.idle()
        XCTAssertEqual(try files.stored(), [a.sha256, b.sha256])

        store.adopt([c.parsed], fetched: true)
        await store.idle()
        XCTAssertEqual(try files.stored(), [b.sha256, c.sha256])
    }

    // A revert names the previous page again: no download, and it becomes the one to keep.
    func testARevertNeedsNoDownloadAndKeepsTheRevertedPage() async {
        let files = MemoryPaywallFiles()
        let (store, transport) = store(serving: [a, b, c], files: files)
        for page in [a, b, a] {
            store.adopt([page.parsed], fetched: true)
            await store.idle()
        }
        XCTAssertEqual(downloads(transport), [a.url, b.url])
        XCTAssertEqual(store.choose("main"), .show(a.parsed, html: PaywallGuard.guarded(a.html)))

        store.adopt([c.parsed], fetched: true)
        await store.idle()
        XCTAssertEqual(try files.stored(), [a.sha256, c.sha256])
    }

    func testAFetchedConfigWithoutAnIdRemovesItsPagesButAStoredOneDoesNot() async {
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [a], files: files)
        store.adopt([a.parsed], fetched: true)
        await store.idle()

        store.adopt([], fetched: false)
        await store.idle()
        XCTAssertEqual(try files.stored(), [a.sha256])

        store.adopt([], fetched: true)
        await store.idle()
        XCTAssertEqual(try files.stored(), [])
        XCTAssertEqual(store.choose("main"), .off)
    }

    func testRetriesAFailedDownloadOnTheNextRound() async {
        let failing = Locked(true)
        let transport = FakeTransport { [a] _ in
            failing.withLock { $0 }
                ? TrevoHTTPResponse(statusCode: 503) : TrevoHTTPResponse(statusCode: 200, body: a.data)
        }
        let (store, _) = store(serving: [], transport: transport)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        XCTAssertEqual(store.choose("main"), .fallback(.notDownloaded, sha256: a.sha256))
        // choose() starts a round of its own; until it ends, the next round below can't start.
        await store.idle()

        failing.withLock { $0 = false }
        store.downloadMissing()
        await store.idle()
        XCTAssertEqual(store.choose("main"), .show(a.parsed, html: PaywallGuard.guarded(a.html)))
    }

    func testSkipsAVersionThatFailedTwiceEvenAfterARelaunch() async {
        let storage = MemoryStorage()
        let files = MemoryPaywallFiles()
        let (first, _) = store(serving: [a, b], files: files, storage: storage)
        first.adopt([a.parsed], fetched: true)
        await first.idle()
        first.recordFailure(a.sha256)
        XCTAssertEqual(first.choose("main"), .show(a.parsed, html: PaywallGuard.guarded(a.html)))
        first.recordFailure(a.sha256)
        XCTAssertEqual(first.choose("main"), .fallback(.skipped, sha256: a.sha256))

        await waitUntil("failures persisted") { [a] in
            storage.json(StorageKey.paywalls)?.objectValue?["failures"]?.objectValue?[a.sha256] == 2
        }
        let (second, _) = store(serving: [a, b], files: files, storage: storage)
        second.hydrate(StoredValue(value: storage[StorageKey.paywalls], failed: false))
        second.adopt([a.parsed], fetched: false)
        XCTAssertEqual(second.choose("main"), .fallback(.skipped, sha256: a.sha256))

        second.adopt([b.parsed], fetched: true)
        await second.idle()
        XCTAssertEqual(second.choose("main"), .show(b.parsed, html: PaywallGuard.guarded(b.html)))
    }

    func testAStoredCopyThatFailsItsHashIsReplaced() async {
        let files = MemoryPaywallFiles()
        let (store, _) = store(serving: [a], files: files)
        store.adopt([a.parsed], fetched: true)
        await store.idle()
        files[a.sha256] = Data("<p>damaged</p>".utf8)

        XCTAssertEqual(store.choose("main"), .fallback(.notDownloaded, sha256: a.sha256))
        await store.idle()
        XCTAssertEqual(store.choose("main"), .show(a.parsed, html: PaywallGuard.guarded(a.html)))
    }

    func testNeverDownloadsOrShowsAPageThisBuildCantShow() async {
        let newer = TestPage("<!doctype html><p>2</p>", id: "newer")
        let gated = TestPage("<!doctype html><p>gated</p>", id: "gated")
        let entries = PaywallConfig.parse(
            .array([newer.entry(format: 2), gated.entry(minSdkVersion: ["ios": "0.3.0"])]))
        let (store, transport) = store(serving: [newer, gated])
        store.adopt(entries, fetched: true)
        await store.idle()

        XCTAssertEqual(downloads(transport), [])
        XCTAssertEqual(store.choose("newer"), .fallback(.unsupported, sha256: newer.sha256))
        XCTAssertEqual(store.choose("gated"), .fallback(.unsupported, sha256: gated.sha256))
    }
}

final class PaywallClientTests: XCTestCase {
    private let page = TestPage("<!doctype html><html><head></head><body>Pro</body></html>")

    func testKnowsTheCurrentPageAfterARelaunchWithoutNetwork() async {
        let storage = MemoryStorage()
        let files = MemoryPaywallFiles()
        let online = makeClient(
            storage: storage,
            transport: paywallTransport(
                config: { [page] in config(paywalls: [page.entry()]) }, pages: { [page] in [page] }),
            pages: files)
        await online.ready()
        await online.paywalls.idle()
        await online.shutdown()

        let offline = makeClient(
            storage: storage, transport: FakeTransport { _ in throw TrevoError("offline") }, pages: files)
        await offline.ready()
        XCTAssertEqual(
            offline.paywalls.choose("main"), .show(page.parsed, html: PaywallGuard.guarded(page.html)))
    }

    // A config stored by an SDK without paywalls must not pin the client to a 304 that hides them.
    func testAConfigStoredWithoutPaywallsIsFetchedInFullOnce() async {
        let storage = MemoryStorage([StorageKey.config: storedConfig([], etag: "\"v1\"")])
        let transport = paywallTransport(
            config: { [page] in config(paywalls: [page.entry()]) }, pages: { [page] in [page] })
        transport.respond { [page] request in
            if request.method == "POST" { return TrevoHTTPResponse(statusCode: 202) }
            if request.url.host == "cdn.trevosdk.com" {
                return TrevoHTTPResponse(statusCode: 200, body: page.data)
            }
            if request.headers["If-None-Match"] != nil { return TrevoHTTPResponse(statusCode: 304) }
            return TrevoHTTPResponse(statusCode: 200, body: try JSON.encode(config(paywalls: [page.entry()])))
        }
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        await client.paywalls.idle()

        let configRequest = transport.requests.first {
            $0.method == "GET" && $0.url.host != "cdn.trevosdk.com"
        }
        XCTAssertNil(configRequest?.headers["If-None-Match"])
        XCTAssertEqual(
            client.paywalls.choose("main"), .show(page.parsed, html: PaywallGuard.guarded(page.html)))
    }

    func testAPageThatFailedOfflineIsFetchedAfterARefreshTheServerAnswers() async {
        let online = Locked(false)
        let transport = FakeTransport { [page] request in
            if request.method == "POST" { return TrevoHTTPResponse(statusCode: 202) }
            if request.url.host == "cdn.trevosdk.com" {
                guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                return TrevoHTTPResponse(statusCode: 200, body: page.data)
            }
            if request.headers["If-None-Match"] != nil {
                guard online.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
                return TrevoHTTPResponse(statusCode: 304)
            }
            return TrevoHTTPResponse(
                statusCode: 200, headers: ["ETag": "\"v1\""],
                body: try JSON.encode(config(paywalls: [page.entry()])))
        }
        let lifecycle = ManualLifecycle()
        let client = makeClient(transport: transport, lifecycle: lifecycle)
        await client.ready()
        await client.paywalls.idle()
        let cdn = { transport.requests.filter { $0.url.host == "cdn.trevosdk.com" }.count }
        XCTAssertEqual(cdn(), 1)

        lifecycle.send(.active)
        await waitUntil("offline refresh") {
            transport.requests.filter { $0.headers["If-None-Match"] != nil }.count == 1
        }
        await client.paywalls.idle()
        XCTAssertEqual(cdn(), 1)

        // Not polled through choose(), which also retries a missing page when the paywall opens.
        online.withLock { $0 = true }
        lifecycle.send(.active)
        await waitUntil("page fetched after the 304") { cdn() == 2 }
        await client.paywalls.idle()
        XCTAssertEqual(
            client.paywalls.choose("main"), .show(page.parsed, html: PaywallGuard.guarded(page.html)))
    }

    func testABadPaywallsFieldCostsNoExperiment() async {
        let experiment = experimentJSON("checkout", [("control", 0), ("treatment", 100)])
        let client = makeClient(
            transport: paywallTransport(
                config: { config([experiment], paywalls: ["broken", ["id": "Main"]]) }, pages: { [] }))
        await client.ready()

        XCTAssertEqual(client.getVariant("checkout"), "treatment")
        XCTAssertEqual(client.paywalls.choose("main"), .off)
    }
}
