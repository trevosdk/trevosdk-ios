import Foundation

/// The app's side of the bridge, as raw values: the host checks every answer before the page sees
/// it, so an app's mistake becomes `FAILED` or a default, never a malformed message.
struct PaywallBridgeHandlers {
    var context: @MainActor () throws -> TrevoValue
    var products: @MainActor () async throws -> TrevoValue
    /// Resolves to `purchased`, `cancelled` or `pending`.
    var buy: @MainActor (String) async throws -> String
    /// Resolves to `restored` or `none`.
    var restore: @MainActor () async throws -> String
    var openLink: @MainActor (String) async throws -> Void
    var variant: @MainActor (String) async throws -> String
    var param: @MainActor (String, TrevoValue) async throws -> TrevoValue?
    var ready: @MainActor () throws -> Void
    var close: @MainActor () throws -> Void
}

/// Bridge version 1, a port of the reference `createBridgeHost` that passes the shared test cases
/// in `packages/paywall-page/src/bridge/vectors.json`.
@MainActor
final class PaywallBridgeHost {
    static let version = 1
    static let maxMessageLength = 65_536
    static let maxNameLength = 200
    private static let maxSafeInteger: Double = 9_007_199_254_740_991

    private static let messages: [String: String] = [
        "BAD_REQUEST": "The message is missing \"v\" or \"call\".",
        "UNSUPPORTED_VERSION": "This app speaks bridge version \(version).",
        "UNKNOWN_CALL": "This app doesn't support that call.",
        "BAD_ARGS": "The call has missing or invalid arguments.",
        "UNKNOWN_PRODUCT": "Only a plan that products() returned can be bought.",
        "UNKNOWN_LINK": "The app didn't name that link.",
        "BUSY": "A purchase or restore is already open.",
        "FAILED": "The app couldn't do that.",
        "CLOSED": "The paywall is closed.",
    ]

    private let handlers: PaywallBridgeHandlers
    private let links: Set<String>
    private let send: @MainActor (String) -> Void
    private let onDiagnostic: @MainActor (String) -> Void
    private var connected = false
    private var readyCalled = false
    private var purchasing = false
    private var listed: Set<String>?
    private(set) var closed = false
    /// App handlers still running, which tests wait on.
    private(set) var inFlight = 0

    init(
        handlers: PaywallBridgeHandlers, links: some Sequence<String>,
        send: @escaping @MainActor (String) -> Void,
        onDiagnostic: @escaping @MainActor (String) -> Void
    ) {
        self.handlers = handlers
        self.links = Set(links)
        self.send = send
        self.onDiagnostic = onDiagnostic
    }

    /// One message from the page, exactly as the WebView handed it over. The checks run in the order
    /// docs/sdk/remote-paywall.md lists.
    func receive(_ raw: Any?) {
        guard let text = raw as? String, text.utf16.count <= Self.maxMessageLength else {
            return onDiagnostic("Dropped a message that is not a string or is too long.")
        }
        guard let message = try? JSON.decode(text) else {
            return onDiagnostic("Dropped a message that is not JSON.")
        }
        guard let object = message.objectValue else {
            return onDiagnostic("Dropped a message that is not an object.")
        }
        guard let id = object["id"]?.numberValue, id.rounded() == id, id >= 1, id <= Self.maxSafeInteger
        else { return onDiagnostic("Dropped a message without a usable id.") }
        connected = true
        guard let version = object["v"]?.numberValue, let call = object["call"]?.stringValue else {
            return fail(id, "BAD_REQUEST")
        }
        if version != Double(Self.version) { return fail(id, "UNSUPPORTED_VERSION") }
        if closed { return fail(id, "CLOSED") }
        let args: [String: TrevoValue]
        switch object["args"] {
        case nil: args = [:]
        case .object(let value)?: args = value
        default: return fail(id, "BAD_ARGS")
        }
        handle(id, call, args)
    }

    /// Tells the page the context changed. Nothing before the page has spoken, or after close.
    func pushContext() {
        guard connected, !closed else { return }
        deliver(["v": .number(Double(Self.version)), "event": "context", "data": context()])
    }

    /// The app closed the paywall itself: the session ends.
    func close() {
        closed = true
    }

    // Per call: its arguments, then its own rules. The order is part of the spec.
    private func handle(_ id: Double, _ call: String, _ args: [String: TrevoValue]) {
        switch call {
        case "context":
            reply(id, context())
        case "products":
            run(id, call, { [handlers] in try await handlers.products() }) { [weak self] value in
                guard let self else { return }
                guard let products = PaywallBridgeNormalize.products(value) else {
                    return self.fail(id, "FAILED")
                }
                self.listed = Set(products.compactMap { $0.objectValue?["id"]?.stringValue })
                self.reply(id, .array(products))
            }
        case "buy":
            guard let productId = args["id"]?.stringValue, !productId.isEmpty else {
                return fail(id, "BAD_ARGS")
            }
            guard listed?.contains(productId) == true else { return fail(id, "UNKNOWN_PRODUCT") }
            if purchasing { return fail(id, "BUSY") }
            purchasing = true
            run(
                id, call, { [handlers] in .string(try await handlers.buy(productId)) },
                answer: outcome(id, ["purchased", "cancelled", "pending"]),
                done: { [weak self] in self?.purchasing = false })
        case "restore":
            if purchasing { return fail(id, "BUSY") }
            purchasing = true
            run(
                id, call, { [handlers] in .string(try await handlers.restore()) },
                answer: outcome(id, ["restored", "none"]),
                done: { [weak self] in self?.purchasing = false })
        case "openLink":
            guard let link = name(args["name"]) else { return fail(id, "BAD_ARGS") }
            guard links.contains(link) else { return fail(id, "UNKNOWN_LINK") }
            run(
                id, call,
                { [handlers] in
                    try await handlers.openLink(link); return .null
                }
            ) { [weak self] _ in
                self?.reply(id, .null)
            }
        case "variant":
            guard let key = name(args["key"]) else { return fail(id, "BAD_ARGS") }
            run(id, call, { [handlers] in .string(try await handlers.variant(key)) }) { [weak self] value in
                guard let variant = value.stringValue, !variant.isEmpty else {
                    self?.fail(id, "FAILED"); return
                }
                self?.reply(id, value)
            }
        case "param":
            guard let param = name(args["name"]), let fallback = args["fallback"], Self.isParamValue(fallback)
            else { return fail(id, "BAD_ARGS") }
            // The page always gets a value of its fallback's type, as getParameter does in every SDK.
            run(
                id, call, { [handlers] in try await handlers.param(param, fallback) ?? .null },
                answer: { [weak self] value in
                    self?.reply(id, Self.sameType(value, fallback) ? value : fallback)
                },
                onError: { [weak self] in self?.reply(id, fallback) })
        case "ready":
            if !readyCalled {
                readyCalled = true
                do { try handlers.ready() } catch {
                    onDiagnostic("ready failed: \(error.localizedDescription)")
                }
            }
            reply(id, .null)
        case "close":
            reply(id, .null)
            closed = true
            do { try handlers.close() } catch { onDiagnostic("close failed: \(error.localizedDescription)") }
        default:
            fail(id, "UNKNOWN_CALL")
        }
    }

    // Runs an app handler that may suspend or throw. An answer that arrives after close is dropped.
    private func run(
        _ id: Double, _ call: String, _ handler: @escaping @MainActor () async throws -> TrevoValue,
        answer: @escaping @MainActor (TrevoValue) -> Void, onError: (@MainActor () -> Void)? = nil,
        done: (@MainActor () -> Void)? = nil
    ) {
        inFlight += 1
        Task { @MainActor [weak self] in
            let result: Result<TrevoValue, any Error>
            do {
                result = .success(try await handler())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.inFlight -= 1
            done?()
            switch result {
            case .success(let value):
                if !self.closed { answer(value) }
            case .failure(let error):
                self.onDiagnostic("\(call) failed: \(error.localizedDescription)")
                if !self.closed {
                    if let onError { onError() } else { self.fail(id, "FAILED") }
                }
            }
        }
    }

    private func run(
        _ id: Double, _ call: String, _ handler: @escaping @MainActor () async throws -> TrevoValue,
        _ answer: @escaping @MainActor (TrevoValue) -> Void
    ) {
        run(id, call, handler, answer: answer)
    }

    private func outcome(_ id: Double, _ outcomes: Set<String>) -> @MainActor (TrevoValue) -> Void {
        { [weak self] value in
            guard let outcome = value.stringValue, outcomes.contains(outcome) else {
                self?.fail(id, "FAILED")
                return
            }
            self?.reply(id, ["outcome": value])
        }
    }

    private func context() -> TrevoValue {
        do {
            return PaywallBridgeNormalize.context(try handlers.context())
        } catch {
            onDiagnostic("context failed: \(error.localizedDescription)")
            return PaywallBridgeNormalize.context(nil)
        }
    }

    private func reply(_ id: Double, _ result: TrevoValue) {
        deliver(["v": .number(Double(Self.version)), "id": .number(id), "ok": true, "result": result])
    }

    private func fail(_ id: Double, _ code: String) {
        deliver([
            "v": .number(Double(Self.version)), "id": .number(id), "ok": false,
            "error": ["code": .string(code), "message": .string(Self.messages[code] ?? code)],
        ])
    }

    private func deliver(_ message: TrevoValue) {
        do {
            send(try JSON.encodeString(message))
        } catch {
            onDiagnostic("Could not deliver a message to the page: \(error.localizedDescription)")
        }
    }

    private func name(_ value: TrevoValue?) -> String? {
        guard let text = value?.stringValue, (1...Self.maxNameLength).contains(text.utf16.count) else {
            return nil
        }
        return text
    }

    private static func isParamValue(_ value: TrevoValue) -> Bool {
        switch value {
        case .string, .bool, .number: return true
        default: return false
        }
    }

    private static func sameType(_ value: TrevoValue, _ fallback: TrevoValue) -> Bool {
        switch (value, fallback) {
        case (.string, .string), (.bool, .bool), (.number, .number): return true
        default: return false
        }
    }

    /// JavaScript that delivers one message: a string literal the page parses itself, with
    /// U+2028 and U+2029 escaped for engines older than ES2019.
    static func deliveryScript(_ message: String) -> String {
        let literal = (try? JSON.encodeString(TrevoValue.string(message))) ?? "\"\""
        let escaped = literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.__trevoReceive(\(escaped));"
    }
}
