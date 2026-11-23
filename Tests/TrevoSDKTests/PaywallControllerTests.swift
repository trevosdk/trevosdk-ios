import Foundation
import XCTest

@testable import TrevoSDK

@MainActor
private final class FakeSurface: PaywallSurface {
    weak var controller: PaywallController?
    // Like the real container, which hands the page to the WebView once WebKit is ready.
    var handsOff = true
    var loaded: [String] = []
    var revealed = 0
    var fallbacks = 0
    var log: [String] = []
    var answered: ((Int) -> Void)?
    private(set) var messages: [TrevoValue] = []

    func load(_ html: String) {
        loaded.append(html)
        if handsOff { controller?.documentHandedOff() }
    }
    func reveal() { revealed += 1 }
    func showFallback() { fallbacks += 1 }

    func evaluate(_ script: String) {
        let prefix = "window.__trevoReceive("
        XCTAssertTrue(script.hasPrefix(prefix) && script.hasSuffix(");"))
        let literal = script.dropFirst(prefix.count).dropLast(2)
        let message = try! JSON.decode(try! JSON.decode(String(literal)).stringValue!)
        messages.append(message)
        let id = message.objectValue?["id"]?.numberValue.map { Int($0) } ?? 0
        log.append("answer:\(id)")
        answered?(id)
    }

    func answer(_ id: Int) -> TrevoValue? {
        messages.last { $0.objectValue?["id"] == .number(Double(id)) }
    }
}

@MainActor
private final class ManualTimer {
    private var next = 0
    private var now: TimeInterval = 0
    private typealias Action = @MainActor () -> Void
    private var pending: [(id: Int, delay: TimeInterval, due: TimeInterval, action: Action)] = []

    var delays: [TimeInterval] { pending.map(\.delay) }

    var schedule: PaywallSchedule {
        { [unowned self] delay, action in
            self.next += 1
            let id = self.next
            self.pending.append((id, delay, self.now + delay, action))
            return { [unowned self] in self.pending.removeAll { $0.id == id } }
        }
    }

    func fire() {
        let actions = pending
        pending.removeAll()
        actions.forEach { $0.action() }
    }

    /// Moves the clock on, firing each timer that comes due.
    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        due.forEach { $0.action() }
    }
}

@MainActor
final class PaywallControllerTests: XCTestCase {
    private let page = TestPage("<!doctype html><html><head></head><body>Pro</body></html>")
    private var transport: FakeTransport!
    private var client: TrevoClient!
    private var surface: FakeSurface!
    private var timer: ManualTimer!
    private var closes = 0
    private var bought: [String] = []
    private var purchase = TrevoPurchaseOutcome.purchased
    private var buyFailure: TrevoError?
    private var holdsBuy = false
    private var heldBuy: CheckedContinuation<Void, Never>?

    private func prepare(experiments: [TrevoValue] = [], paywalls: [TrevoValue]? = nil, serve: Bool = true)
        async
    {
        let page = page
        transport = paywallTransport(
            config: { config(experiments, paywalls: .array(paywalls ?? [page.entry()])) },
            pages: { serve ? [page] : [] })
        client = makeClient(transport: transport)
        await client.ready()
        await client.paywalls.idle()
        surface = FakeSurface()
        timer = ManualTimer()
    }

    private func controller(id: String = "main", readyTimeout: TimeInterval = 1) -> PaywallController {
        let controller = PaywallController(
            client: client, id: id,
            handlers: PaywallAppHandlers(
                products: { [TrevoPaywallProduct(id: "yearly", price: "$49.99", period: "P1Y")] },
                buy: { [unowned self] id in
                    self.bought.append(id)
                    if self.holdsBuy { await withCheckedContinuation { self.heldBuy = $0 } }
                    if let failure = self.buyFailure { throw failure }
                    return self.purchase
                },
                restore: { .nothingToRestore },
                links: ["terms": URL(string: "https://example.com/terms")!],
                open: { _ in true },
                onClose: { [unowned self] in
                    self.closes += 1
                    self.surface.log.append("close")
                }),
            readyTimeout: readyTimeout, schedule: timer.schedule)
        controller.surface = surface
        surface.controller = controller
        return controller
    }

    private func send(_ controller: PaywallController, _ id: Int, _ call: String, _ args: TrevoValue? = nil) {
        var request: [String: TrevoValue] = ["v": 1, "id": .number(Double(id)), "call": .string(call)]
        if let args { request["args"] = args }
        controller.receive(try! JSON.encodeString(TrevoValue.object(request)))
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func fallbackEvents() async -> [[String: TrevoValue]] {
        await events(PaywallController.fallbackEvent)
    }

    private func events(_ name: String) async -> [[String: TrevoValue]] {
        await client.flush()
        return transport.sentEvents.filter { $0["event"] == .string(name) }
            .compactMap { $0["properties"]?.objectValue }
    }

    // Opens a purchase that stays open until the test resumes `heldBuy`.
    private func purchasing() async -> PaywallController {
        let controller = controller()
        controller.start()
        send(controller, 1, "products")
        await settle()
        holdsBuy = true
        send(controller, 2, "buy", ["id": "yearly"])
        await settle()
        return controller
    }

    func testRevealsThePageOnReadyAndTheLimitNoLongerApplies() async {
        await prepare()
        let controller = controller()
        controller.start()
        XCTAssertEqual(surface.loaded, [PaywallGuard.guarded(page.html)])
        XCTAssertEqual(timer.delays, [PaywallController.startTimeout])

        send(controller, 1, "ready")
        timer.fire()
        XCTAssertEqual(surface.revealed, 1)
        XCTAssertEqual(surface.fallbacks, 0)
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
    }

    func testATimeoutShowsTheAppsPaywallReportsItAndTwoSkipTheVersion() async {
        await prepare()
        for _ in 0..<2 {
            let controller = controller()
            controller.start()
            send(controller, 1, "context")
            timer.fire()
            send(controller, 2, "ready")
            XCTAssertEqual(surface.revealed, 0)
        }
        XCTAssertEqual(surface.fallbacks, 2)

        controller().start()
        XCTAssertEqual(surface.loaded.count, 2)
        let reasons = await fallbackEvents().map { $0["reason"] }
        XCTAssertEqual(reasons, ["timeout", "timeout", "skipped"])
        let first = await fallbackEvents().first
        XCTAssertEqual(first, ["paywall": "main", "reason": "timeout", "sha256": .string(page.sha256)])
    }

    // Slow WebKit starts and memory kills aren't the page's fault, so neither skips the version.
    func testOnlyATimeoutAfterThePagesScriptSpokeCountsAgainstTheVersion() async {
        await prepare()
        for _ in 0..<2 {
            let controller = controller()
            controller.start()
            timer.fire()
        }
        for _ in 0..<2 {
            let controller = controller()
            controller.start()
            send(controller, 1, "ready")
            controller.contentProcessTerminated()
        }

        controller().start()
        XCTAssertEqual(surface.loaded.count, 5)
        let reasons = await fallbackEvents().map { $0["reason"] }
        XCTAssertEqual(reasons, ["timeout", "timeout", "crashed", "crashed"])
    }

    // A cold WebView took up to 5.3 s to run the page's script, past the 2 s ready limit.
    func testTheReadyLimitStartsAtThePagesFirstMessage() async {
        await prepare()
        let controller = controller(readyTimeout: 2)
        controller.start()
        XCTAssertEqual(timer.delays, [PaywallController.startTimeout])

        timer.advance(5.4)
        send(controller, 1, "context")
        XCTAssertEqual(timer.delays, [2])
        timer.advance(1.9)
        send(controller, 2, "ready")
        XCTAssertEqual(surface.revealed, 1)
        XCTAssertEqual(surface.fallbacks, 0)
    }

    func testTheReadyLimitRunsFromTheFirstMessageOnlyNotEachLaterOne() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "context")
        timer.advance(0.999)
        send(controller, 2, "products")
        timer.advance(0.001)

        XCTAssertEqual(surface.fallbacks, 1)
        let reasons = await fallbackEvents().map { $0["reason"] }
        XCTAssertEqual(reasons, ["timeout"])
    }

    func testAPageWhoseFirstMessageClosesItIsNeverTimed() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "close")
        timer.advance(60)

        XCTAssertEqual(closes, 1)
        XCTAssertEqual(surface.fallbacks, 0)
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
        self.controller().start()
        XCTAssertEqual(surface.loaded.count, 2)
    }

    func testTheStartLimitIsNeverShorterThanTheAppsReadyLimit() async {
        await prepare()
        controller(readyTimeout: 10).start()
        XCTAssertEqual(timer.delays, [10])
    }

    func testAPageTheWebViewNeverGetsInTimeFallsBackSilently() async {
        await prepare()
        surface.handsOff = false
        let controller = controller()
        controller.start()
        XCTAssertEqual(timer.delays, [PaywallController.startTimeout])
        timer.fire()
        controller.documentHandedOff()

        XCTAssertEqual(surface.fallbacks, 1)
        XCTAssertEqual(timer.delays, [])
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
        surface.handsOff = true
        self.controller().start()
        XCTAssertEqual(surface.loaded.count, 2)
    }

    // Compiling the network rules and making a cold WebView can take seconds on their own.
    func testAPageHandedOffAfterTheReadyLimitStillShowsWhenItIsReady() async {
        await prepare()
        surface.handsOff = false
        let controller = controller(readyTimeout: 2)
        controller.start()
        timer.advance(4)
        controller.documentHandedOff()
        send(controller, 1, "ready")
        timer.advance(60)

        XCTAssertEqual(surface.revealed, 1)
        XCTAssertEqual(surface.fallbacks, 0)
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
    }

    func testTheStartLimitRunsFromStartNotFromTheHandoffAndNeverSkipsTheVersion() async {
        await prepare()
        surface.handsOff = false
        for _ in 0..<2 {
            let controller = controller(readyTimeout: 2)
            controller.start()
            timer.advance(7)
            controller.documentHandedOff()
            timer.advance(1)
        }

        XCTAssertEqual(surface.fallbacks, 2)
        let reasons = await fallbackEvents().map { $0["reason"] }
        XCTAssertEqual(reasons, ["timeout", "timeout"])
        controller().start()
        XCTAssertEqual(surface.loaded.count, 3)
    }

    func testALimitThatIsntAPositiveNumberIsTheDefaultAndALongOneIsAMinute() {
        XCTAssertEqual(PaywallController.limit(.infinity), 5)
        XCTAssertEqual(PaywallController.limit(.nan), 5)
        XCTAssertEqual(PaywallController.limit(0), 5)
        XCTAssertEqual(PaywallController.limit(-1), 5)
        XCTAssertEqual(PaywallController.limit(1e12), 60)
        XCTAssertEqual(PaywallController.limit(0.5), 0.5)
    }

    func testAnIdOutsideTheFolderRuleIsReportedOnceAndShowsTheAppsPaywall() async {
        let errors = ErrorLog()
        let page = TestPage("<!doctype html><p>x</p>", id: "main")
        transport = paywallTransport(config: { config(paywalls: [page.entry()]) }, pages: { [page] })
        client = makeClient(transport: transport, errors: errors)
        await client.ready()
        surface = FakeSurface()
        timer = ManualTimer()

        controller(id: "Main").start()
        controller(id: "Main").start()

        XCTAssertEqual(surface.fallbacks, 2)
        XCTAssertEqual(surface.loaded, [])
        XCTAssertEqual(errors.all.filter { $0.contains("\"Main\"") }.count, 1)
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
    }

    func testNoPageNamedShowsTheAppsPaywallAndReportsNothing() async {
        await prepare(paywalls: [])
        controller().start()

        XCTAssertEqual(surface.fallbacks, 1)
        XCTAssertEqual(surface.loaded, [])
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
    }

    func testAPageNotDownloadedYetReportsWhy() async {
        await prepare(serve: false)
        controller().start()

        XCTAssertEqual(surface.fallbacks, 1)
        let reasons = await fallbackEvents().map { $0["reason"] }
        XCTAssertEqual(reasons, ["not_downloaded"])
    }

    func testAPurchaseIsAnsweredBeforeThePaywallCloses() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "products")
        await settle()
        XCTAssertEqual(
            surface.answer(1)?.objectValue?["result"],
            [["id": "yearly", "price": "$49.99", "period": "P1Y"]])

        purchase = .cancelled
        send(controller, 2, "buy", ["id": "yearly"])
        await settle()
        XCTAssertEqual(closes, 0)

        purchase = .purchased
        send(controller, 3, "buy", ["id": "yearly"])
        await settle()
        XCTAssertEqual(bought, ["yearly", "yearly"])
        XCTAssertEqual(Array(surface.log.suffix(2)), ["answer:3", "close"])
        XCTAssertEqual(closes, 1)
    }

    func testAPurchaseThePageMadeIsTrackedWithoutAValueAndACancelledOneIsNot() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "products")
        await settle()
        purchase = .cancelled
        send(controller, 2, "buy", ["id": "yearly"])
        await settle()
        purchase = .purchased
        send(controller, 3, "buy", ["id": "yearly"])
        await settle()

        let purchases = await events(PaywallController.purchaseEvent)
        XCTAssertEqual(purchases, [["paywall": "main", "product": "yearly", "sha256": .string(page.sha256)]])
    }

    func testAPageThatEndsDuringAPurchaseWaitsForItAndClosesWhenItGoesThrough() async {
        await prepare()
        let controller = await purchasing()
        controller.contentProcessTerminated()
        timer.fire()
        XCTAssertEqual(surface.fallbacks, 0)
        XCTAssertEqual(timer.delays, [])

        heldBuy?.resume()
        await settle()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(surface.fallbacks, 0)
        let fallbacks = await fallbackEvents()
        XCTAssertEqual(fallbacks, [])
        let purchases = await events(PaywallController.purchaseEvent)
        XCTAssertEqual(purchases.count, 1)
    }

    func testAPageThatEndsAfterAPurchaseWentThroughButBeforeTheCloseStillCloses() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "products")
        await settle()
        // The answer goes out before the scheduled close runs.
        surface.answered = { [weak controller] id in
            if id == 2 { controller?.contentProcessTerminated() }
        }
        send(controller, 2, "buy", ["id": "yearly"])
        await settle()

        XCTAssertEqual(closes, 1)
        XCTAssertEqual(surface.fallbacks, 0)
        let fallbacks = await fallbackEvents()
        XCTAssertEqual(fallbacks, [])
    }

    func testAPageThatFailsDuringAPurchaseFallsBackWithTheFirstReasonOnceThePurchaseEndsWithoutOne() async {
        await prepare()
        purchase = .cancelled
        let crashed = await purchasing()
        crashed.contentProcessTerminated()
        XCTAssertEqual(surface.fallbacks, 0)
        heldBuy?.resume()
        await settle()
        XCTAssertEqual(surface.fallbacks, 1)

        buyFailure = TrevoError("store unavailable")
        let timedOut = await purchasing()
        timer.fire()
        send(timedOut, 3, "ready")
        XCTAssertEqual(surface.answer(3)?.objectValue?["error"]?.objectValue?["code"], "CLOSED")
        XCTAssertEqual(surface.revealed, 0)
        timedOut.contentProcessTerminated()
        XCTAssertEqual(surface.fallbacks, 1)
        heldBuy?.resume()
        await settle()
        XCTAssertEqual(surface.fallbacks, 2)

        XCTAssertEqual(closes, 0)
        let fallbacks = await fallbackEvents()
        XCTAssertEqual(
            fallbacks,
            [
                ["paywall": "main", "reason": "crashed", "sha256": .string(page.sha256)],
                ["paywall": "main", "reason": "timeout", "sha256": .string(page.sha256)],
            ])
    }

    func testThePageClosingEndsTheSession() async {
        await prepare()
        let controller = controller()
        controller.start()
        send(controller, 1, "close")
        send(controller, 2, "ready")

        XCTAssertEqual(closes, 1)
        XCTAssertEqual(surface.answer(2)?.objectValue?["error"]?.objectValue?["code"], "CLOSED")
        XCTAssertEqual(surface.revealed, 0)
    }

    func testVariantsCountTheUserAndParamsKeepTheFallbacksType() async {
        let experiment = experimentJSON(
            "paywall-plans", [("control", 0), ("variant", 100)],
            params: ["variant": ["trial_days": 14, "headline": "Go Pro"]])
        await prepare(experiments: [experiment])
        let controller = controller()
        controller.start()
        send(controller, 1, "variant", ["key": "paywall-plans"])
        send(controller, 2, "param", ["name": "trial_days", "fallback": 7])
        send(controller, 3, "param", ["name": "headline", "fallback": 7])
        await settle()

        XCTAssertEqual(surface.answer(1)?.objectValue?["result"], "variant")
        XCTAssertEqual(surface.answer(2)?.objectValue?["result"], 14)
        XCTAssertEqual(surface.answer(3)?.objectValue?["result"], 7)
        await client.flush()
        XCTAssertTrue(transport.sentEvents.contains { $0["event"] == "$experiment_exposure" })
    }

    func testContextCarriesTheLocaleAndScreenAndIsPushedOnlyWhenItChanges() async {
        await prepare()
        client.setLocale("pt-BR")
        let controller = controller()
        controller.screen = PaywallScreen(dark: true, fontScale: 1.3, safeArea: (47, 0, 34, 0))
        controller.start()
        send(controller, 1, "context")
        XCTAssertEqual(
            surface.answer(1)?.objectValue?["result"],
            [
                "locale": "pt-BR", "colorScheme": "dark", "fontScale": 1.3,
                "safeArea": ["top": 47, "right": 0, "bottom": 34, "left": 0], "platform": "ios",
            ])

        controller.screen = PaywallScreen(dark: true, fontScale: 1.3, safeArea: (47, 0, 34, 0))
        XCTAssertEqual(surface.messages.count, 1)
        controller.screen = PaywallScreen(dark: false, fontScale: 1.3, safeArea: (47, 0, 34, 0))
        XCTAssertEqual(surface.messages.last?.objectValue?["event"], "context")
        XCTAssertEqual(surface.messages.last?.objectValue?["data"]?.objectValue?["colorScheme"], "light")
    }

    func testStoppingEndsTheSessionAndTheLimit() async {
        await prepare()
        let controller = controller()
        controller.start()
        controller.stop()
        timer.fire()
        send(controller, 1, "ready")

        XCTAssertEqual(surface.fallbacks, 0)
        XCTAssertEqual(surface.answer(1)?.objectValue?["error"]?.objectValue?["code"], "CLOSED")
        let events = await fallbackEvents()
        XCTAssertEqual(events, [])
    }
}
