#if os(iOS)
    import SwiftUI

    /// The remote paywall Trevo publishes under `id`, or `fallback`, the app's own paywall, whenever
    /// that page can't show. See `TrevoPaywallViewController`.
    ///
    /// ```swift
    /// TrevoPaywall(
    ///     client: trevo, id: "main",
    ///     products: { try await billing.products() },
    ///     buy: { id in try await billing.purchase(id) },
    ///     restore: { try await billing.restore() },
    ///     links: ["terms": termsURL, "privacy": privacyURL]
    /// ) {
    ///     PaywallScreen()
    /// }
    /// ```
    @available(iOSApplicationExtension, unavailable)
    public struct TrevoPaywall<Fallback: View>: View {
        @StateObject private var model: PaywallModel
        @Environment(\.dismiss) private var dismiss
        private let onClose: (@MainActor () -> Void)?
        private let fallback: () -> Fallback

        /// The page and its session belong to the first render: a new `id` needs a new view identity.
        /// - Parameter onClose: Called when the page closes, or after a purchase or restore succeeds.
        ///   Defaults to the environment's `dismiss`.
        public init(
            client: TrevoClient, id: String,
            products: @escaping @MainActor () async throws -> [TrevoPaywallProduct],
            buy: @escaping @MainActor (String) async throws -> TrevoPurchaseOutcome,
            restore: @escaping @MainActor () async throws -> TrevoRestoreOutcome,
            links: [String: URL] = [:], onClose: (@MainActor () -> Void)? = nil,
            readyTimeout: TimeInterval = 2, @ViewBuilder fallback: @escaping () -> Fallback
        ) {
            _model = StateObject(
                wrappedValue: PaywallModel(
                    client: client, id: id, products: products, buy: buy, restore: restore, links: links,
                    readyTimeout: readyTimeout))
            self.onClose = onClose
            self.fallback = fallback
        }

        public var body: some View {
            if model.showsFallback {
                fallback()
            } else {
                PaywallPage(model: model, close: onClose ?? { dismiss() }).ignoresSafeArea()
            }
        }
    }

    /// Owns one showing's controller and stands in for the WebView until SwiftUI creates it.
    @available(iOSApplicationExtension, unavailable)
    @MainActor
    final class PaywallModel: ObservableObject, PaywallSurface {
        @Published private(set) var showsFallback = false
        var close: @MainActor () -> Void = {}
        private let controller: PaywallController
        private var container: PaywallWebContainer?
        private var pendingPage: String?

        init(
            client: TrevoClient, id: String,
            products: @escaping @MainActor () async throws -> [TrevoPaywallProduct],
            buy: @escaping @MainActor (String) async throws -> TrevoPurchaseOutcome,
            restore: @escaping @MainActor () async throws -> TrevoRestoreOutcome,
            links: [String: URL], readyTimeout: TimeInterval
        ) {
            weak var weakSelf: PaywallModel?
            controller = PaywallController(
                client: client, id: id,
                handlers: PaywallAppHandlers(
                    products: products, buy: buy, restore: restore, links: links,
                    open: { url in await UIApplication.shared.open(url) },
                    onClose: { weakSelf?.close() }),
                readyTimeout: readyTimeout)
            weakSelf = self
            controller.surface = self
            // Before the first render, so the app's own paywall shows at once when no page can.
            controller.start()
        }

        func makeContainer() -> PaywallWebContainer {
            let container = PaywallWebContainer(controller: controller)
            self.container = container
            if let html = pendingPage {
                pendingPage = nil
                container.load(html)
            }
            return container
        }

        func stop() {
            controller.stop()
            container?.tearDown()
        }

        func load(_ html: String) {
            if let container { container.load(html) } else { pendingPage = html }
        }

        func evaluate(_ script: String) {
            container?.evaluate(script)
        }

        func reveal() {
            container?.reveal()
        }

        func showFallback() {
            container?.tearDown()
            pendingPage = nil
            showsFallback = true
        }
    }

    @available(iOSApplicationExtension, unavailable)
    private struct PaywallPage: UIViewRepresentable {
        let model: PaywallModel
        let close: @MainActor () -> Void

        func makeCoordinator() -> PaywallModel {
            model
        }

        func makeUIView(context: Context) -> PaywallWebContainer {
            model.close = close
            return model.makeContainer()
        }

        func updateUIView(_ container: PaywallWebContainer, context: Context) {
            model.close = close
            container.updateScreen()
        }

        // A dismissed sheet only dismantles the view: the session must end here too.
        static func dismantleUIView(_ container: PaywallWebContainer, coordinator model: PaywallModel) {
            model.stop()
        }
    }
#endif
