import Foundation
import XCTest

@testable import TrevoSDK

/// The shared conformance corpus. A failure here means this SDK buckets, parses or shapes
/// differently from every other Trevo SDK.
final class CorpusTests: XCTestCase {
    private static let corpus: [String: TrevoValue] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TrevoSDKTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // sdks
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("packages/contracts/src/corpus/vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSON.decode(data).objectValue!
    }()

    private func cases(_ category: String) -> [[String: TrevoValue]] {
        let cases = Self.corpus[category]?.arrayValue?.compactMap(\.objectValue) ?? []
        XCTAssertFalse(cases.isEmpty, "corpus has no \(category) cases")
        return cases
    }

    func testHash() {
        for kase in cases("hash") {
            let name = kase["name"]!.stringValue!
            XCTAssertEqual(
                Double(Assignment.fnv1a32(kase["input"]!.stringValue!)), kase["hash"]!.numberValue!,
                name)
        }
    }

    func testAssignment() {
        for kase in cases("assignment") {
            let name = kase["name"]!.stringValue!
            let key = kase["experimentKey"]!.stringValue!
            let bucketingId = kase["bucketingId"]!.stringValue!
            XCTAssertEqual(
                Double(Assignment.fnv1a32("\(bucketingId):\(key)")), kase["hash"]!.numberValue!,
                "\(name): hash")
            XCTAssertEqual(
                Double(Assignment.bucket(bucketingId, key)), kase["bucket"]!.numberValue!,
                "\(name): bucket")

            // Built directly: the corpus walks one-variant lists, which the config parser rejects.
            let variants = kase["variants"]!.arrayValue!.compactMap(\.objectValue).map {
                ExperimentVariant(
                    name: $0["name"]!.stringValue!, trafficSplit: Int($0["trafficSplit"]!.numberValue!))
            }
            let config = ExperimentConfig(experimentKey: key, variants: variants)
            XCTAssertEqual(
                Assignment.assignVariant(bucketingId, config), kase["expected"]!.stringValue!, name)
        }
    }

    func testConfigParse() {
        for kase in cases("configParse") {
            let name = kase["name"]!.stringValue!
            let result = ConfigParser.parse(kase["body"]!)
            XCTAssertEqual((try? result.get()) != nil, kase["valid"]!.boolValue!, name)
            if let keys = kase["experimentKeys"]?.arrayValue, let parsed = try? result.get() {
                XCTAssertEqual(parsed.map(\.experimentKey), keys.compactMap(\.stringValue), name)
            }
        }
    }

    func testBuildEvent() throws {
        for kase in cases("buildEvent") {
            let name = kase["name"]!.stringValue!
            let input = kase["input"]!.objectValue!
            let identity = input["identity"]!.objectValue!
            let result = EventBuilder.build(
                EventInput(
                    eventName: input["eventName"]!.stringValue!,
                    properties: input["properties"]?.objectValue,
                    userId: identity["userId"]?.stringValue,
                    anonymousId: identity["anonymousId"]?.stringValue,
                    timestamp: input["timestamp"]!.stringValue!,
                    sdkVersion: input["sdkVersion"]?.stringValue,
                    appVersion: input["appVersion"]?.stringValue,
                    insertId: input["insertId"]?.stringValue,
                    preview: input["preview"]?.boolValue ?? false))

            let expected = kase["expected"]!.objectValue!
            switch result {
            case .success(let event):
                XCTAssertEqual(expected["ok"], .bool(true), name)
                XCTAssertEqual(try JSON.decode(JSON.encode(event)), expected["event"], name)
            case .failure(let reason):
                XCTAssertEqual(expected["ok"], .bool(false), name)
                XCTAssertEqual(reason.rawValue, expected["reason"]?.stringValue, name)
            }
        }
    }

    func testExposureDedup() {
        for kase in cases("exposureDedup") {
            let name = kase["name"]!.stringValue!
            var deduper = ExposureDeduper()
            for step in kase["steps"]!.arrayValue!.compactMap(\.objectValue) {
                let logged = deduper.shouldLog(
                    identity: step["identity"]!.stringValue!,
                    experimentKey: step["experimentKey"]!.stringValue!,
                    variant: step["variantName"]!.stringValue!,
                    nowMs: Int64(step["atMs"]!.numberValue!))
                XCTAssertEqual(logged, step["expectLog"]!.boolValue!, "\(name) at \(step["atMs"]!)")
            }
        }
    }
}
