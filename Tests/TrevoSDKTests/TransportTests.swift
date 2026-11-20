import Foundation
import XCTest

@testable import TrevoSDK

final class TransportTests: XCTestCase {
    private func stream(_ count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for _ in 0..<count { continuation.yield(0x61) }
            continuation.finish()
        }
    }

    func testABodyAtTheLimitIsKept() async throws {
        let data = try await URLSessionTransport.collect(stream(10), declaredLength: -1, limit: 10)
        XCTAssertEqual(data.count, 10)
    }

    // A server can leave the length out, or compress: only the bytes read decide.
    func testAnUndeclaredBodyPastTheLimitIsRefused() async {
        do {
            _ = try await URLSessionTransport.collect(stream(11), declaredLength: -1, limit: 10)
            XCTFail("a body past the limit was kept")
        } catch {
            XCTAssertTrue(error is ResponseTooLong)
        }
    }

    // The body here is empty, so only the declared length can refuse it.
    func testADeclaredLengthPastTheLimitIsRefusedBeforeReading() async {
        do {
            _ = try await URLSessionTransport.collect(stream(0), declaredLength: 11, limit: 10)
            XCTFail("a declared length past the limit was read")
        } catch {
            XCTAssertTrue(error is ResponseTooLong)
        }
    }
}
