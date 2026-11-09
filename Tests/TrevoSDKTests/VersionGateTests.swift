import XCTest

@testable import TrevoSDK

final class VersionGateTests: XCTestCase {
    func testOrdersBySegmentNumberNotText() {
        XCTAssertEqual(VersionGate.compare("1.10.0", "1.9.0"), 1)
        XCTAssertEqual(VersionGate.compare("2.0", "10.0"), -1)
    }

    func testTreatsMissingSegmentsAsZero() {
        XCTAssertEqual(VersionGate.compare("1.4", "1.4.0"), 0)
    }

    func testIgnoresPreReleaseAndBuildSuffixes() {
        XCTAssertEqual(VersionGate.compare("1.4.0-beta.2", "1.4.0"), 0)
        XCTAssertEqual(VersionGate.compare("1.4.0+42", "1.4.1"), -1)
    }

    func testAdmitsEverythingWithoutAMinimum() {
        XCTAssertTrue(VersionGate.admits(appVersion: nil, platform: "ios", minimum: nil))
        XCTAssertTrue(
            VersionGate.admits(appVersion: nil, platform: "ios", minimum: MinAppVersion(ios: "")))
    }

    func testAppliesOnlyThisPlatformsMinimum() {
        let minimum = MinAppVersion(ios: "1.4.0", android: "9.0.0")
        XCTAssertTrue(VersionGate.admits(appVersion: "1.4.0", platform: "ios", minimum: minimum))
        XCTAssertFalse(VersionGate.admits(appVersion: "1.3.9", platform: "ios", minimum: minimum))
        XCTAssertTrue(
            VersionGate.admits(
                appVersion: "1.0.0", platform: "ios", minimum: MinAppVersion(android: "9.0.0")))
    }

    // Fails closed: the SDK can't prove the build has the variant's code.
    func testExcludesABuildWhoseVersionIsUnknown() {
        let minimum = MinAppVersion(ios: "1.4.0")
        XCTAssertFalse(VersionGate.admits(appVersion: nil, platform: "ios", minimum: minimum))
        XCTAssertFalse(VersionGate.admits(appVersion: "beta", platform: "ios", minimum: minimum))
    }
}
