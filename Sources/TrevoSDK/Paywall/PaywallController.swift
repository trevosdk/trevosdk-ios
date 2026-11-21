import Foundation

/// What the platform view does for the controller. The controller holds every rule; the view only
/// loads, delivers and swaps, and calls `documentHandedOff()` once the WebView has the page.
@MainActor
protocol PaywallSurface: AnyObject {
    func load(_ html: String)
    func evaluate(_ script: String)
    func reveal()
    func showFallback()
}

/// The app's billing functions and links, as the public views take them.
struct PaywallAppHandlers {
    var products: @MainActor () async throws -> [TrevoPaywallProduct]
    var buy: @MainActor (String) async throws -> TrevoPurchaseOutcome
    var restore: @MainActor () async throws -> TrevoRestoreOutcome
    var links: [String: URL]
    /// Opens a link with the system; false when nothing could open it.
    var open: @MainActor (URL) async -> Bool
    var onClose: @MainActor () -> Void
}

/// What the view knows about its screen, for the page's context.
struct PaywallScreen: Equatable {
    var dark = false
    var fontScale = 1.0
    var safeArea = (top: 0.0, right: 0.0, bottom: 0.0, left: 0.0)

    static func == (a: PaywallScreen, b: PaywallScreen) -> Bool {
        a.dark == b.dark && a.fontScale == b.fontScale && a.safeArea == b.safeArea
    }
}

/// Starts a one-shot timer and returns what cancels it.
typealias PaywallSchedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

/// One showing of a remote paywall: picks the page, runs the bridge, reveals on `ready`, and falls
/// back to the app's own paywall on any failure, never while a purchase or restore is open.
/// Spec: docs/sdk/remote-paywall.md, section 5.
@MainActor
final class PaywallController {
    enum Phase: Equatable {
        case idle, loading, shown, fallback, closed
    }

    static let defaultReadyTimeout: TimeInterval = 2
    static let maxReadyTimeout: TimeInterval = 60
    // A cold WebView can take ~3 s to start a page, more with a screen reader on.
    static let startTimeout: TimeInterval = 5
    static let fallbackEvent = "$paywall_fallback"
    static let purchaseEvent = "purchase"

    weak var surface: (any PaywallSurface)?
    var screen = PaywallScreen() {
        didSet { if screen != oldValue { contextChanged() } }
    }
    private(set) var phase = Phase.idle
    private(set) var host: PaywallBridgeHost?

    private let client: TrevoClient
    private let id: String
    private let handlers: PaywallAppHandlers
    private let readyTimeout: TimeInterval
    private let schedule: PaywallSchedule
    private var sha256: String?
    private var cancelTimer: (() -> Void)?
    private var handedOff = false
    private var committed = false
    // Locked so the nonisolated deinit can cancel it when the view goes without calling stop().
    private let subscription = Locked<TrevoSubscription?>(nil)
    private var lastContext: TrevoValue?
    private var openPurchases = 0
    // The app's own paywall over an open store sheet invites a second purchase.
    private var heldFallback: PaywallFallbackReason?
    // A failure between a purchase going through and the close it scheduled must not fall back.
    private var closePending = false

    init(
        client: TrevoClient, id: String, handlers: PaywallAppHandlers,
        readyTimeout: TimeInterval = defaultReadyTimeout,
        schedule: @escaping PaywallSchedule = PaywallController.sleepTimer
    ) {
        self.client = client
        self.id = id
        self.handlers = handlers
        self.readyTimeout = Self.limit(readyTimeout)
        self.schedule = schedule
    }

    deinit {
        subscription.withLock { $0 }?.cancel()
    }

    static func limit(_ readyTimeout: TimeInterval) -> TimeInterval {
        guard readyTimeout.isFinite, readyTimeout > 0 else { return defaultReadyTimeout }
        return min(readyTimeout, maxReadyTimeout)
    }

    func start() {
        guard phase == .idle else { return }
        guard PaywallConfig.isPaywallId(id) else {
            if client.paywalls.firstReport(of: id) {
                client.report(TrevoError("TrevoPaywall id \"\(id)\" can't name a paywall folder"))
            }
            phase = .fallback
            surface?.showFallback()
            return
        }
        switch client.paywalls.choose(id) {
        case .off:
            phase = .fallback
            surface?.showFallback()
        case .fallback(let reason, let sha256):
            self.sha256 = sha256
            fallBack(reason)
        case .show(let entry, let html):
            sha256 = entry.sha256
            phase = .loading
            host = PaywallBridgeHost(
                handlers: bridgeHandlers(), links: handlers.links.keys,
                send: { [weak self] message in
                    self?.surface?.evaluate(PaywallBridgeHost.deliveryScript(message))
                },
                onDiagnostic: { [weak self] message in self?.diagnose(message) })
            let subscription = client.onChange { [weak self] in self?.contextChanged() }
            self.subscription.withLock { $0 = subscription }
            lastContext = context
            // One start limit covers compiling the rules, making the WebView and starting the page.
            let startLimit = min(max(readyTimeout, Self.startTimeout), Self.maxReadyTimeout)
            cancelTimer = schedule(startLimit) { [weak self] in self?.notStartedInTime() }
            surface?.load(html)
        }
    }

    /// The WebView has the document: from here a missed start limit is reported as a timeout.
    func documentHandedOff() {
        guard phase == .loading else { return }
        handedOff = true
    }

    /// The WebView committed the page's navigation: the ready limit starts now, and a timeout from
    /// here is the page's fault.
    func pageCommitted() {
        guard phase == .loading, !committed else { return }
        committed = true
        // A page that already failed mid-purchase must not be timed, and so counted, again.
        guard heldFallback == nil, !closePending else { return }
        cancelTimer?()
        cancelTimer = schedule(readyTimeout) { [weak self] in self?.timedOut() }
    }

    /// The platform has no WebView the paywall can use.
    func webViewUnavailable() {
        guard phase == .idle || phase == .loading else { return }
        fail(.noWebView)
    }

    func diagnose(_ message: String) {
        client.report(TrevoError("Paywall bridge: \(message)"))
    }

    /// A message from the page's main frame.
    func receive(_ raw: Any?) {
        host?.receive(raw)
    }

    // Not counted against the version: the system ends content processes to free memory.
    func contentProcessTerminated() {
        guard phase == .loading || phase == .shown else { return }
        fail(.crashed)
    }

    /// The view went away: the bridge session ends and nothing more reaches the app.
    func stop() {
        guard phase != .closed else { return }
        end()
    }

    // A WebView too slow to even start the page isn't the page's fault, so it doesn't count.
    private func timedOut() {
        guard phase == .loading else { return }
        if committed, let sha256 { client.paywalls.recordFailure(sha256) }
        fail(.timeout)
    }

    // Before the WebView has the page there is no page to blame, so it falls back silently.
    private func notStartedInTime() {
        guard phase == .loading else { return }
        guard handedOff else {
            end()
            phase = .fallback
            surface?.showFallback()
            return
        }
        timedOut()
    }

    private func fail(_ reason: PaywallFallbackReason) {
        guard !closePending else { return }
        guard openPurchases == 0 else {
            cancelTimer?()
            cancelTimer = nil
            host?.close()
            heldFallback = heldFallback ?? reason
            return
        }
        fallBack(reason)
    }

    private func fallBack(_ reason: PaywallFallbackReason) {
        end()
        phase = .fallback
        client.track(
            Self.fallbackEvent,
            properties: [
                "paywall": .string(id), "reason": .string(reason.rawValue), "sha256": .string(sha256 ?? ""),
            ])
        surface?.showFallback()
    }

    private func revealed() {
        guard phase == .loading else { return }
        cancelTimer?()
        cancelTimer = nil
        phase = .shown
        surface?.reveal()
    }

    private func closeFromPage() {
        end()
        handlers.onClose()
    }

    // After a purchase or restore: the answer goes out first, then the app closes the paywall.
    private func closeAfterAnswer() {
        closePending = true
        Task { @MainActor [weak self] in
            guard let self, self.phase == .loading || self.phase == .shown else { return }
            self.closeFromPage()
        }
    }

    private func whilePurchasing(
        _ run: @MainActor () async throws -> (outcome: String, closes: Bool)
    ) async throws -> String {
        openPurchases += 1
        let result: (outcome: String, closes: Bool)
        do {
            result = try await run()
        } catch {
            purchaseEnded(closing: false)
            throw error
        }
        purchaseEnded(closing: result.closes)
        if result.closes { closeAfterAnswer() }
        return result.outcome
    }

    // The page that failed mid-purchase can't hear the outcome, so a purchase closes the paywall here.
    private func purchaseEnded(closing: Bool) {
        openPurchases -= 1
        guard openPurchases == 0, let reason = heldFallback else { return }
        heldFallback = nil
        guard phase == .loading || phase == .shown else { return }
        if closing { closeFromPage() } else { fallBack(reason) }
    }

    private func trackPurchase(_ product: String) {
        client.track(
            Self.purchaseEvent,
            properties: [
                "paywall": .string(id), "product": .string(product), "sha256": .string(sha256 ?? ""),
            ])
    }

    private func end() {
        cancelTimer?()
        cancelTimer = nil
        subscription.withLock { subscription in
            defer { subscription = nil }
            return subscription
        }?.cancel()
        host?.close()
        phase = .closed
    }

    private func contextChanged() {
        let next = context
        guard next != lastContext else { return }
        lastContext = next
        host?.pushContext()
    }

    private var context: TrevoValue {
        let inset = screen.safeArea
        return PaywallBridgeNormalize.context(
            .object([
                "locale": client.shownLocale.map(TrevoValue.string) ?? .null,
                "colorScheme": .string(screen.dark ? "dark" : "light"),
                "fontScale": .number(screen.fontScale),
                "safeArea": [
                    "top": .number(inset.top), "right": .number(inset.right),
                    "bottom": .number(inset.bottom), "left": .number(inset.left),
                ],
                "platform": "ios",
            ]))
    }

    private func bridgeHandlers() -> PaywallBridgeHandlers {
        let handlers = handlers
        let client = client
        return PaywallBridgeHandlers(
            context: { [weak self] in self?.context ?? .null },
            products: { .array(try await handlers.products().map(\.json)) },
            buy: { [weak self] productId in
                guard let self else { return try await handlers.buy(productId).rawValue }
                return try await self.whilePurchasing {
                    let outcome = try await handlers.buy(productId)
                    if outcome == .purchased { self.trackPurchase(productId) }
                    return (outcome.rawValue, outcome == .purchased)
                }
            },
            restore: { [weak self] in
                guard let self else { return try await handlers.restore().rawValue }
                return try await self.whilePurchasing {
                    let outcome = try await handlers.restore()
                    return (outcome.rawValue, outcome == .restored)
                }
            },
            openLink: { name in
                guard let url = handlers.links[name], await handlers.open(url) else {
                    throw TrevoError("Nothing opened the \(name) link")
                }
            },
            variant: { key in client.getVariant(key) },
            param: { name, fallback in
                switch fallback {
                case .string(let text): return .string(client.getParameter(name, default: text))
                case .bool(let flag): return .bool(client.getParameter(name, default: flag))
                case .number(let number): return .number(client.getParameter(name, default: number))
                default: return nil
                }
            },
            ready: { [weak self] in self?.revealed() },
            close: { [weak self] in self?.closeFromPage() })
    }

    static let sleepTimer: PaywallSchedule = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { action() }
        }
        return { task.cancel() }
    }
}
