#if os(iOS)
    import UIKit
    import WebKit

    /// The locked-down WebView both public views show the page in. Spec: docs/sdk/remote-paywall.md,
    /// section 5, and its iOS column.
    @MainActor
    final class PaywallWebContainer: UIView {
        private weak var controller: PaywallController?
        private var webView: WKWebView?

        init(controller: PaywallController) {
            self.controller = controller
            super.init(frame: .zero)
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            updateScreen()
        }

        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            updateScreen()
        }

        func updateScreen() {
            let insets = safeAreaInsets
            controller?.screen = PaywallScreen(
                dark: traitCollection.userInterfaceStyle == .dark,
                fontScale: UIFontMetrics.default.scaledValue(for: 100, compatibleWith: traitCollection) / 100,
                safeArea: (
                    Double(insets.top), Double(insets.right), Double(insets.bottom), Double(insets.left)
                ))
        }

        func load(_ html: String) {
            Task { @MainActor [weak self] in
                let rules: WKContentRuleList
                do {
                    rules = try await Self.networkRules()
                } catch {
                    self?.controller?.diagnose("WebKit refused the paywall's network rules: \(error)")
                    self?.controller?.webViewUnavailable()
                    return
                }
                guard let self, self.controller?.phase == .loading else { return }
                let webView = self.makeWebView(rules: rules)
                self.webView = webView
                webView.frame = self.bounds
                webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.addSubview(webView)
                webView.loadHTMLString(html, baseURL: nil)
                self.controller?.documentHandedOff()
            }
        }

        func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script) { [weak self] _, error in
                // The script's own result is undefined, which WebKit may call unsupported.
                guard let error, (error as? WKError)?.code != .javaScriptResultTypeIsUnsupported else {
                    return
                }
                self?.controller?.diagnose(
                    "Could not deliver a message to the page: \(error.localizedDescription)")
            }
        }

        func reveal() {
            guard let webView else { return }
            webView.alpha = 1
            webView.isUserInteractionEnabled = true
            webView.accessibilityElementsHidden = false
        }

        func tearDown() {
            guard let webView else { return }
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
            self.webView = nil
        }

        fileprivate func received(_ message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            controller?.receive(message.body)
        }

        private func makeWebView(rules: WKContentRuleList) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.dataDetectorTypes = []
            configuration.allowsAirPlayForMediaPlayback = false
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let content = configuration.userContentController
            content.add(rules)
            content.addUserScript(
                WKUserScript(
                    source: PaywallGuard.documentStartScript, injectionTime: .atDocumentStart,
                    forMainFrameOnly: false))
            content.add(PaywallMessageRelay(self), name: "trevo")

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.allowsLinkPreview = false
            // Invisible, untouchable and silent to VoiceOver until the page calls ready().
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            webView.accessibilityElementsHidden = true
            return webView
        }

        // WebKit keeps a compiled list under its identifier, so a changed list needs a new one.
        private static let rulesIdentifier = "trevo-paywall-no-network-1"
        private static let retiredIdentifiers = ["trevo-paywall-no-network"]
        private static let blockNetwork = """
            [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},\
            {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}}]
            """

        private static func networkRules() async throws -> WKContentRuleList {
            guard let store = WKContentRuleListStore.default() else {
                throw TrevoError("WebKit has no content rule list store")
            }
            if let rules = try? await store.contentRuleList(forIdentifier: rulesIdentifier) {
                return rules
            }
            for identifier in retiredIdentifiers {
                try? await store.removeContentRuleList(forIdentifier: identifier)
            }
            guard
                let rules = try await store.compileContentRuleList(
                    forIdentifier: rulesIdentifier, encodedContentRuleList: blockNetwork)
            else { throw TrevoError("WebKit compiled no content rule list") }
            return rules
        }
    }

    extension PaywallWebContainer: WKNavigationDelegate, WKUIDelegate {
        // The first load and moves within it are about:blank; anything else would leave the page.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            controller?.contentProcessTerminated()
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
            initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
        ) async -> WKPermissionDecision {
            .deny
        }

        func webView(
            _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }
    }

    /// WebKit retains its script message handlers, so this holds the container weakly.
    @MainActor
    private final class PaywallMessageRelay: NSObject, WKScriptMessageHandler {
        private weak var target: PaywallWebContainer?

        init(_ target: PaywallWebContainer) {
            self.target = target
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            target?.received(message)
        }
    }
#endif
