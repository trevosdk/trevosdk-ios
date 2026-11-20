import Foundation
import XCTest

@testable import TrevoSDK

/// The shared remote paywall test cases. A failure means this SDK reads config, guards a page or
/// answers the page differently from every other Trevo SDK.
@MainActor
final class PaywallVectorsTests: XCTestCase {
    private static func load(_ path: String) -> [String: TrevoValue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TrevoSDKTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // sdks
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("packages/paywall-page/src/\(path)")
        return try! JSON.decode(Data(contentsOf: url)).objectValue!
    }

    private static let view = load("view/vectors.json")
    private static let bridge = load("bridge/vectors.json")

    private func cases(_ file: [String: TrevoValue], _ key: String) -> [[String: TrevoValue]] {
        let cases = file[key]?.arrayValue?.compactMap(\.objectValue) ?? []
        XCTAssertFalse(cases.isEmpty, "no \(key) cases")
        return cases
    }

    func testGuardAndVersionsMatchTheSharedOnes() {
        XCTAssertEqual(Self.view["guard"]?.stringValue, PaywallGuard.markup)
        XCTAssertEqual(Self.view["documentStartScript"]?.stringValue, PaywallGuard.documentStartScript)
        XCTAssertEqual(Self.view["fallbackEvent"]?.stringValue, PaywallController.fallbackEvent)
        XCTAssertEqual(Self.view["purchaseEvent"]?.stringValue, PaywallController.purchaseEvent)
        XCTAssertEqual(
            Self.view["fallbackReasons"]?.arrayValue?.compactMap(\.stringValue),
            PaywallFallbackReason.allCases.map(\.rawValue))
        XCTAssertEqual(Self.view["format"]?.numberValue, Double(PaywallConfig.formatVersion))
        XCTAssertEqual(Self.view["bridge"]?.numberValue, Double(PaywallBridgeHost.version))
    }

    func testConfig() {
        for kase in cases(Self.view, "config") {
            let parsed = PaywallConfig.parse(kase["paywalls"]).map(PaywallConfig.json)
            XCTAssertEqual(.array(parsed), kase["expected"], kase["name"]!.stringValue!)
        }
    }

    func testShowable() {
        for kase in cases(Self.view, "showable") {
            let entry = PaywallConfig.parse(.array([kase["entry"]!])).first!
            let showable = PaywallConfig.canShow(
                entry, sdk: kase["sdk"]!.stringValue!, sdkVersion: kase["sdkVersion"]!.stringValue!)
            XCTAssertEqual(showable, kase["expected"]?.boolValue, kase["name"]!.stringValue!)
        }
    }

    func testGuardInsertion() {
        for kase in cases(Self.view, "insertion") {
            let html = Array(kase["html"]!.stringValue!.utf16)
            let at = Int(kase["insertAt"]!.numberValue!)
            let expected =
                String(decoding: html[..<at], as: UTF16.self) + PaywallGuard.markup
                + String(decoding: html[at...], as: UTF16.self)
            XCTAssertEqual(
                PaywallGuard.guarded(kase["html"]!.stringValue!), expected, kase["name"]!.stringValue!)
        }
    }

    func testBridgeSessions() async {
        for session in cases(Self.bridge, "sessions") {
            await run(session)
        }
    }

    private func run(_ session: [String: TrevoValue]) async {
        let name = session["name"]!.stringValue!
        let setup = session["setup"]?.objectValue ?? [:]
        let harness = BridgeHarness(setup)
        var sent: [String] = []
        let host = PaywallBridgeHost(
            handlers: harness.handlers,
            links: setup["links"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            send: { sent.append($0) }, onDiagnostic: { _ in })
        for (index, step) in (session["steps"]?.arrayValue ?? []).compactMap(\.objectValue).enumerated() {
            let place = "\(name), step \(index + 1)"
            sent.removeAll()
            harness.calls.removeAll()
            if let request = step["send"] { host.receive(try! JSON.encodeString(request)) }
            if let raw = step["sendRaw"]?.stringValue { host.receive(raw) }
            if let sized = step["sendSized"]?.objectValue {
                let json = try! JSON.encodeString(sized["request"]!)
                let padding = Int(sized["length"]!.numberValue!) - json.utf16.count
                host.receive("{" + String(repeating: " ", count: padding) + json.dropFirst())
            }
            if let call = step["settle"]?.stringValue { harness.settle(call) }
            if step["push"] != nil { host.pushContext() }
            if step["appClose"]?.boolValue == true { host.close() }
            await settled(host, harness, place)

            let received = sent.map { try! JSON.decode($0) }
            if let calls = step["calls"]?.arrayValue {
                XCTAssertEqual(harness.calls, calls.compactMap(\.stringValue), place)
            }
            if let expected = step["expect"] {
                XCTAssertEqual(.array(received.map(withoutErrorMessage)), expected, place)
            }
            if let length = step["expectResultLength"]?.numberValue {
                XCTAssertEqual(received.count, 1, place)
                XCTAssertEqual(received.first?.objectValue?["ok"], .bool(true), place)
                XCTAssertEqual(received.first?.objectValue?["result"]?.arrayValue?.count, Int(length), place)
            }
        }
    }

    /// Every handler has answered except the ones a case holds open.
    private func settled(_ host: PaywallBridgeHost, _ harness: BridgeHarness, _ place: String) async {
        for _ in 0..<10_000 {
            if host.inFlight == harness.holding { return }
            await Task.yield()
        }
        XCTFail("handlers never settled: \(place)")
    }

    /// Errors are compared by code; their message is free text.
    private func withoutErrorMessage(_ message: TrevoValue) -> TrevoValue {
        guard var object = message.objectValue, let code = object["error"]?.objectValue?["code"] else {
            return message
        }
        object["error"] = .object(["code": code])
        return .object(object)
    }
}

/// The stand-in app docs/sdk/remote-paywall.md section 6 describes.
@MainActor
private final class BridgeHarness {
    struct Failure: Error {}

    var calls: [String] = []
    private(set) var holding = 0
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var productsCall = 0
    private let setup: [String: TrevoValue]

    init(_ setup: [String: TrevoValue]) {
        self.setup = setup
    }

    func settle(_ call: String) {
        guard let continuation = held.removeValue(forKey: call) else { return }
        holding -= 1
        continuation.resume()
    }

    var handlers: PaywallBridgeHandlers {
        PaywallBridgeHandlers(
            context: { [unowned self] in self.setup["context"] ?? .object([:]) },
            products: { [unowned self] in
                self.calls.append("products")
                let answer: TrevoValue?
                if let byCall = self.setup["productsByCall"]?.arrayValue {
                    answer = byCall[min(self.productsCall, byCall.count - 1)]
                } else {
                    answer = self.setup["products"]
                }
                self.productsCall += 1
                if self.setup["productsThrows"]?.boolValue == true || answer == .string("throw") {
                    throw Failure()
                }
                return answer ?? .array([])
            },
            buy: { [unowned self] id in
                self.calls.append("buy:\(id)")
                return try await self.outcome("buy")
            },
            restore: { [unowned self] in
                self.calls.append("restore")
                return try await self.outcome("restore")
            },
            openLink: { [unowned self] name in
                self.calls.append("openLink:\(name)")
                if self.setup["openLinkThrows"]?.boolValue == true { throw Failure() }
            },
            variant: { [unowned self] key in
                self.calls.append("variant:\(key)")
                if self.setup["variantThrows"]?.boolValue == true { throw Failure() }
                return self.setup["variants"]?.objectValue?[key]?.stringValue ?? "control"
            },
            param: { [unowned self] name, _ in
                self.calls.append("param:\(name)")
                return self.setup["params"]?.objectValue?[name]
            },
            ready: { [unowned self] in
                self.calls.append("ready")
                if self.setup["readyThrows"]?.boolValue == true { throw Failure() }
            },
            close: { [unowned self] in self.calls.append("close") })
    }

    private func outcome(_ call: String) async throws -> String {
        let configured = setup[call]?.objectValue
        if configured?["hold"]?.boolValue == true {
            holding += 1
            await withCheckedContinuation { held[call] = $0 }
        }
        guard let outcome = configured?["outcome"]?.stringValue, outcome != "throw" else { throw Failure() }
        return outcome
    }
}
