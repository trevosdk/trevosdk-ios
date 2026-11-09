import Foundation
import XCTest

@testable import TrevoSDK

private let checkout = experimentJSON("checkout", [("control", 50), ("treatment", 50)])

final class IdentityTests: XCTestCase {
    func testMintsAnAnonymousIdOnceAndKeepsItAcrossLaunches() async {
        let storage = MemoryStorage()
        let first = makeClient(storage: storage)
        await first.ready()
        let id = first.anonymousId
        await first.shutdown()

        let second = makeClient(storage: storage)
        await second.ready()
        XCTAssertNotNil(id)
        XCTAssertEqual(second.anonymousId, id)
    }

    // A locked device can't read the stored id; replacing it would re-bucket the user next launch.
    func testDoesNotOverwriteAnIdItCouldNotRead() async {
        let storage = MemoryStorage(
            [StorageKey.anonymousId: "stored-id"], unreadable: [StorageKey.anonymousId])
        let client = makeClient(storage: storage)
        await client.ready()
        await client.shutdown()
        XCTAssertEqual(storage[StorageKey.anonymousId], "stored-id")
    }

    func testResetStartsANewParticipant() async {
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        await client.ready()
        client.identify("user-1")
        let before = client.anonymousId
        client.reset()
        await client.shutdown()

        XCTAssertNotEqual(client.anonymousId, before)
        XCTAssertNil(storage[StorageKey.userId])
        XCTAssertEqual(storage[StorageKey.anonymousId], client.anonymousId)
    }

    func testRestoresTheIdentifiedUserOnTheNextLaunch() async {
        let transport = FakeTransport()
        let storage = MemoryStorage([StorageKey.userId: "user-7"])
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        client.track("opened")
        await client.flush()
        XCTAssertEqual(transport.sentEvents.first?["userId"], "user-7")
    }

    func testDiscardsAStoredUserIdIngestionWouldReject() async {
        let storage = MemoryStorage([StorageKey.userId: String(repeating: "u", count: 256)])
        let client = makeClient(storage: storage)
        await client.ready()
        await client.shutdown()
        XCTAssertNil(storage[StorageKey.userId])
    }

    func testRejectsABlankUserId() async {
        let errors = ErrorLog()
        let storage = MemoryStorage()
        let client = makeClient(storage: storage, errors: errors)
        await client.ready()
        client.identify("   ")
        await client.shutdown()
        XCTAssertNil(storage[StorageKey.userId])
        XCTAssertTrue(errors.all.contains("identify requires a userId"))
    }
}

final class AssignmentTests: XCTestCase {
    func testAssignsFromTheUserIdOnceIdentified() async {
        let user = identity(bucketing: "checkout", toward: 1)
        let client = makeClient(transport: FakeTransport(config: configBody([checkout])))
        await client.ready()
        client.identify(user)
        XCTAssertEqual(client.getVariant("checkout"), "treatment")
    }

    func testReturnsControlForAnExperimentNotInConfig() async {
        let transport = FakeTransport(config: configBody([checkout]))
        let client = makeClient(transport: transport)
        await client.ready()
        XCTAssertEqual(client.getVariant("unknown"), "control")
        await client.flush()
        XCTAssertTrue(transport.sentEvents.isEmpty)
    }

    func testRecordsOneExposurePerIdentityAndExperiment() async {
        let transport = FakeTransport(config: configBody([checkout]))
        let client = makeClient(transport: transport)
        await client.ready()
        let variant = client.getVariant("checkout")
        _ = client.getVariant("checkout")
        await client.flush()

        let exposures = transport.sentEvents.filter { $0["event"] == "$experiment_exposure" }
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(
            exposures.first?["properties"],
            .object(["experimentKey": "checkout", "variantName": .string(variant)]))
    }

    func testServesAShippedWinnerAndRestoresTheRememberedArmIfTheTestReopens() async {
        let user = identity(bucketing: "checkout", toward: 0)
        let storage = MemoryStorage([
            StorageKey.userId: user,
            StorageKey.assignments: try! JSON.encodeString(
                TrevoValue.object(["\(user):checkout": "control"])),
        ])
        let transport = FakeTransport(
            config: configBody([experimentJSON("checkout", [("control", 0), ("treatment", 100)])]))
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        XCTAssertEqual(client.getVariant("checkout"), "treatment")

        transport.respond(FakeTransport.route(config: configBody([checkout]), ingest: 202))
        await client.config.refresh()
        XCTAssertEqual(client.getVariant("checkout"), "control")
    }

    func testKeepsAnOlderBuildInControlWithoutAnExposure() async {
        let gated = experimentJSON(
            "checkout", [("control", 0), ("treatment", 100)], minAppVersion: ["ios": "3.0.0"])
        let transport = FakeTransport(config: configBody([gated]))
        let client = makeClient(transport: transport, appVersion: "2.9.0")
        await client.ready()
        XCTAssertEqual(client.getVariant("checkout"), "control")
        await client.flush()
        XCTAssertTrue(transport.sentEvents.isEmpty)
    }

    func testStopsServingABootstrappedExperimentTheServerNoLongerReturns() async {
        let bootstrap = ExperimentConfig(
            experimentKey: "checkout",
            variants: [
                ExperimentVariant(name: "control", trafficSplit: 0),
                ExperimentVariant(name: "treatment", trafficSplit: 100),
            ])
        let client = makeClient(bootstrap: [bootstrap])
        await client.ready()
        XCTAssertEqual(client.getVariant("checkout"), "control")
    }
}

final class ConfigTests: XCTestCase {
    func testKeepsTheStoredConfigWhenOffline() async {
        let storage = MemoryStorage([
            StorageKey.config: storedConfig([
                experimentJSON("checkout", [("control", 0), ("treatment", 100)])
            ])
        ])
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        XCTAssertEqual(client.getVariant("checkout"), "treatment")
    }

    func testPersistsAFetchedConfigWithItsETagAndRevalidatesWithIt() async {
        let storage = MemoryStorage()
        let body = configBody([checkout])
        let transport = FakeTransport(FakeTransport.route(config: body, ingest: 202, etag: "\"v1\""))
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        await client.shutdown()
        XCTAssertEqual(storage.json(StorageKey.config)?.objectValue?["etag"], "\"v1\"")

        transport.respond { _ in TrevoHTTPResponse(statusCode: 304) }
        let next = makeClient(storage: storage, transport: transport)
        await next.ready()
        XCTAssertEqual(transport.requests.last?.headers["If-None-Match"], "\"v1\"")
        XCTAssertTrue(next.config.hasConfig)
        XCTAssertNotNil(next.config.experiment("checkout"))
    }

    func testRejectsAnInvalidPayload() async {
        let errors = ErrorLog()
        let storage = MemoryStorage([StorageKey.config: storedConfig([checkout])])
        let transport = FakeTransport(
            config: configBody([experimentJSON("broken", [("only", 100)])]))
        let client = makeClient(storage: storage, transport: transport, errors: errors)
        await client.ready()
        XCTAssertNotNil(client.config.experiment("checkout"))
        XCTAssertNil(client.config.experiment("broken"))
        XCTAssertTrue(errors.all.contains { $0.hasPrefix("Trevo config response invalid") })
    }

    func testDiscardsAnUnusableStoredConfig() async {
        let storage = MemoryStorage([StorageKey.config: "{\"experiments\": [null]"])
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        await client.shutdown()
        XCTAssertNil(storage[StorageKey.config])
    }

    func testRefreshesConfigWhenTheAppReturnsToTheForeground() async {
        let lifecycle = ManualLifecycle()
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycle: lifecycle)
        await client.ready()
        let fetches = transport.requests.filter { $0.method == "GET" }.count

        lifecycle.send(.active)
        await waitUntil("a foreground fetch") {
            transport.requests.filter { $0.method == "GET" }.count > fetches
        }
    }
}

final class EventTests: XCTestCase {
    func testKeepsEventsWhenDeliveryFailsAndSendsThemLater() async {
        let storage = MemoryStorage()
        let transport = FakeTransport { request in
            if request.method == "POST" { throw URLError(.notConnectedToInternet) }
            return TrevoHTTPResponse(statusCode: 200, body: configBody([]))
        }
        let first = makeClient(storage: storage, transport: transport)
        await first.ready()
        first.track("purchase", properties: ["amount": 9.5])
        await first.shutdown()
        XCTAssertEqual(storage.json(StorageKey.queue)?.arrayValue?.count, 1)

        let delivering = FakeTransport()
        let second = makeClient(storage: storage, transport: delivering)
        await second.ready()
        await second.flush()
        XCTAssertEqual(delivering.sentEvents.map { $0["event"] }, ["purchase"])
        XCTAssertEqual(delivering.sentEvents.first?["properties"], .object(["amount": 9.5]))
    }

    func testDropsABatchTheServerRefusesInsteadOfRetryingForever() async {
        let errors = ErrorLog()
        let transport = FakeTransport(ingest: 400)
        let client = makeClient(transport: transport, errors: errors)
        await client.ready()
        client.track("signup")
        await client.flush()
        XCTAssertEqual(client.events.count, 0)
        XCTAssertTrue(errors.all.contains { $0.hasPrefix("Trevo dropped 1 event(s)") })
    }

    func testRetriesAfterAServerError() async {
        let transport = FakeTransport(ingest: 503)
        let client = makeClient(transport: transport)
        await client.ready()
        client.track("signup")
        await client.flush()
        XCTAssertEqual(client.events.count, 1)
    }

    func testStampsEveryEventWithTheBuildAndAnIdempotencyKey() async {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, appVersion: "4.1.0")
        await client.ready()
        client.track("signup")
        client.track("signup")
        await client.flush()

        let events = transport.sentEvents
        XCTAssertEqual(events.map { $0["appVersion"] }, ["4.1.0", "4.1.0"])
        XCTAssertEqual(events.first?["sdkVersion"], .string(TrevoSDKVersion.sdkVersion))
        let insertIds = events.compactMap { $0["insertId"]?.stringValue }
        XCTAssertEqual(Set(insertIds).count, 2)
        let body = transport.requests.last { $0.method == "POST" }?.body
        XCTAssertNotNil(body.flatMap { try? JSON.decode($0).objectValue?["sentAt"] })
    }

    func testKeepsEventsTrackedBeforeStoredStateLoads() async {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.track("launched")
        await client.ready()
        await client.flush()
        XCTAssertEqual(transport.sentEvents.map { $0["event"] }, ["launched"])
        XCTAssertNotNil(transport.sentEvents.first?["anonymousId"])
    }

    // A failed read left the stored backlog in place; persisting the empty queue would erase it.
    func testDoesNotOverwriteAStoredQueueItCouldNotRead() async {
        let storage = MemoryStorage([StorageKey.queue: "[]"], unreadable: [StorageKey.queue])
        let transport = FakeTransport { request in
            if request.method == "POST" { throw URLError(.timedOut) }
            return TrevoHTTPResponse(statusCode: 200, body: configBody([]))
        }
        let client = makeClient(storage: storage, transport: transport)
        await client.ready()
        client.track("signup")
        await client.shutdown()
        XCTAssertEqual(storage[StorageKey.queue], "[]")
    }

    func testRejectsAnEventNameIngestionWouldDrop() async {
        let errors = ErrorLog()
        let client = makeClient(errors: errors)
        await client.ready()
        client.track("checkout completed")
        XCTAssertEqual(client.events.count, 0)
        XCTAssertTrue(errors.all.contains { $0.hasSuffix("ignored: name-charset") })
    }

    func testFlushesWhenTheAppMovesToTheBackground() async {
        let lifecycle = ManualLifecycle()
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycle: lifecycle)
        await client.ready()
        client.track("viewed")
        lifecycle.send(.background)
        await waitUntil("a background flush") { !transport.sentEvents.isEmpty }
    }

    func testStopsObservingTheAppOnShutdown() async {
        let lifecycle = ManualLifecycle()
        let client = makeClient(lifecycle: lifecycle)
        await client.ready()
        XCTAssertTrue(lifecycle.isSubscribed)
        await client.shutdown()
        XCTAssertFalse(lifecycle.isSubscribed)
    }
}

final class ParameterTests: XCTestCase {
    private func client(_ experiments: [TrevoValue], user: String) async -> TrevoClient {
        let client = makeClient(
            storage: MemoryStorage([StorageKey.userId: user]),
            transport: FakeTransport(config: configBody(experiments)))
        await client.ready()
        return client
    }

    func testServesTheAssignedArmsValue() async {
        let user = identity(bucketing: "paywall", toward: 1)
        let client = await client(
            [
                experimentJSON(
                    "paywall", [("control", 50), ("treatment", 50)],
                    params: ["treatment": ["paywall.headline": "Try it free", "paywall.days": 14]])
            ], user: user)
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Try it free")
        XCTAssertEqual(client.getParameter("paywall.days", default: 7), 14)
    }

    func testServesTheDefaultForAnArmWithoutAValueOrAValueOfAnotherType() async {
        let user = identity(bucketing: "paywall", toward: 0)
        let client = await client(
            [
                experimentJSON(
                    "paywall", [("control", 50), ("treatment", 50)],
                    params: ["control": ["paywall.days": "fourteen", "paywall.ratio": 0.5]])
            ], user: user)
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Subscribe")
        XCTAssertEqual(client.getParameter("paywall.days", default: 7), 7)
        XCTAssertEqual(client.getParameter("paywall.ratio", default: 1), 1)
        XCTAssertEqual(client.getParameter("paywall.ratio", default: 1.0), 0.5)
    }

    func testPrefersARunningTestOverAShippedWinner() async {
        let user = identity(bucketing: "headline-test", toward: 1)
        let client = await client(
            [
                experimentJSON(
                    "old-winner", [("control", 0), ("treatment", 100)],
                    params: ["treatment": ["paywall.headline": "Shipped"]]),
                experimentJSON(
                    "headline-test", [("control", 50), ("treatment", 50)],
                    params: ["treatment": ["paywall.headline": "Testing"]]),
            ], user: user)
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Testing")
    }

    func testServesTheDefaultWhenNoExperimentSetsTheParameter() async {
        let client = await client([checkout], user: "user-1")
        XCTAssertFalse(client.getParameter("paywall.enabled", default: false))
    }
}

final class ChangeTests: XCTestCase {
    func testNotifiesListenersAfterStartupAndIdentityChanges() async {
        // Startup waits on the first fetch, so the listener is in place before it finishes.
        let gate = Gate()
        let route = FakeTransport.route(config: configBody([]), ingest: 202)
        let client = makeClient(
            transport: FakeTransport { request in
                await gate.wait()
                return try await route(request)
            })
        let count = Counter()
        let subscription = client.onChange { count.increment() }
        gate.open()
        await client.ready()
        await waitUntil("the startup notification") { count.value == 1 }

        client.identify("user-1")
        await waitUntil("the identify notification") { count.value == 2 }

        subscription.cancel()
        client.identify("user-2")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(count.value, 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let released = waiting
        waiting = []
        lock.unlock()
        released.forEach { $0.resume() }
    }
}

final class StartupTests: XCTestCase {
    func testIsReadyWithoutAnApiKeyAndServesControl() async {
        let errors = ErrorLog()
        let client = TrevoClient(
            options: TrevoOptions(
                apiKey: " ", storage: MemoryStorage(), transport: FakeTransport(),
                lifecycle: ManualLifecycle(), onError: { errors.record($0) }))
        await client.ready()
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(client.getVariant("checkout"), "control")
        XCTAssertTrue(errors.all.first?.hasPrefix("TrevoClient requires an apiKey") == true)
    }

    // An app binary can be unpacked, so a secret key in one is a leaked key.
    func testRefusesASecretKey() async {
        let transport = FakeTransport()
        let errors = ErrorLog()
        let client = TrevoClient(
            options: TrevoOptions(
                apiKey: "tsk_secret_abc", storage: MemoryStorage(), transport: transport,
                lifecycle: ManualLifecycle(), onError: { errors.record($0) }))
        await client.ready()
        client.track("signup")
        await client.flush()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(errors.all.first?.hasPrefix("TrevoClient refuses a secret key") == true)
    }

    func testDoesNotOverwriteStoredAssignmentsItCouldNotRead() async {
        let storage = MemoryStorage(
            [StorageKey.assignments: "{}"], unreadable: [StorageKey.assignments])
        let client = makeClient(storage: storage, transport: FakeTransport(config: configBody([checkout])))
        await client.ready()
        _ = client.getVariant("checkout")
        await client.shutdown()
        XCTAssertEqual(storage[StorageKey.assignments], "{}")
    }

    // The system can suspend the app while the background flush is still in flight.
    func testPersistsTheQueueBeforeTheBackgroundFlushFinishes() async {
        let gate = Gate()
        let storage = MemoryStorage()
        let lifecycle = ManualLifecycle()
        let route = FakeTransport.route(config: configBody([]), ingest: 202)
        let transport = FakeTransport { request in
            if request.method == "POST" { await gate.wait() }
            return try await route(request)
        }
        let client = makeClient(storage: storage, transport: transport, lifecycle: lifecycle)
        await client.ready()
        client.track("purchase")
        lifecycle.send(.background)
        // Inside the one-second debounce, so only the background persist can have written it.
        await waitUntil("the queue on disk", timeout: 0.5) { storage[StorageKey.queue] != nil }
        gate.open()
    }
}
