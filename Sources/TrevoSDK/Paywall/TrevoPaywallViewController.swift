#if os(iOS)
    import UIKit

    /// Shows the remote paywall Trevo publishes under `id`, or the app's own paywall (`fallback`)
    /// whenever that page can't show: none published, not downloaded yet, or it failed to draw in
    /// time. The page runs in a WebView with no network, storage or permissions, and buys only
    /// through the functions passed here.
    @available(iOSApplicationExtension, unavailable)
    @MainActor
    public final class TrevoPaywallViewController: UIViewController {
        private let controller: PaywallController
        private let makeFallback: @MainActor () -> UIViewController
        private lazy var container = PaywallWebContainer(controller: controller)
        private var fallback: UIViewController?

        /// - Parameters:
        ///   - links: Pages the paywall may open by name, such as `terms` and `privacy`.
        ///   - readyTimeout: How long the page may take to draw before the app's own paywall shows.
        ///   - onClose: Called when the page closes, or after a purchase or restore succeeds.
        ///     Defaults to dismissing this controller, or popping it from its navigation stack.
        public init(
            client: TrevoClient, id: String,
            products: @escaping @MainActor () async throws -> [TrevoPaywallProduct],
            buy: @escaping @MainActor (String) async throws -> TrevoPurchaseOutcome,
            restore: @escaping @MainActor () async throws -> TrevoRestoreOutcome,
            links: [String: URL] = [:], readyTimeout: TimeInterval = 2,
            onClose: (@MainActor () -> Void)? = nil,
            fallback: @escaping @MainActor () -> UIViewController
        ) {
            weak var weakSelf: TrevoPaywallViewController?
            controller = PaywallController(
                client: client, id: id,
                handlers: PaywallAppHandlers(
                    products: products, buy: buy, restore: restore, links: links,
                    open: { url in await UIApplication.shared.open(url) },
                    onClose: {
                        if let onClose { onClose() } else { weakSelf?.closeSelf() }
                    }),
                readyTimeout: readyTimeout)
            makeFallback = fallback
            super.init(nibName: nil, bundle: nil)
            weakSelf = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            pin(container)
            controller.surface = self
            container.updateScreen()
            controller.start()
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || isMovingFromParent || parent?.isBeingDismissed == true { stop() }
        }

        func stop() {
            controller.stop()
            container.tearDown()
        }

        private func closeSelf() {
            if presentingViewController != nil {
                dismiss(animated: true)
            } else {
                navigationController?.popViewController(animated: true)
            }
        }

        private func pin(_ child: UIView) {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
    }

    @available(iOSApplicationExtension, unavailable)
    extension TrevoPaywallViewController: PaywallSurface {
        func load(_ html: String) {
            container.load(html)
        }

        func evaluate(_ script: String) {
            container.evaluate(script)
        }

        func reveal() {
            container.reveal()
        }

        func showFallback() {
            container.tearDown()
            container.removeFromSuperview()
            guard fallback == nil else { return }
            let child = makeFallback()
            fallback = child
            addChild(child)
            pin(child.view)
            child.didMove(toParent: self)
        }
    }
#endif
