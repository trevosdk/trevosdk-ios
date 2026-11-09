import Foundation

enum Constants {
    static let controlVariant = "control"
    static let exposureEvent = "$experiment_exposure"
    static let platform = "ios"

    /// Bucket space for variant assignment. Frozen: see docs/sdk/bucketing-spec.md.
    static let bucketSpace: UInt32 = 10_000

    static let maxEventNameLength = 500
    static let maxPropertiesBytes = 8_192
    static let exposureDedupWindowMs: Int64 = 600_000
    static let exposureDedupMaxKeys = 1_000

    static let minPollInterval: TimeInterval = 30
    static let minFlushInterval: TimeInterval = 1
    static let serverMaxBatchSize = 500
    static let requestTimeout: TimeInterval = 15

    /// Bounds a long offline stretch. Oldest dropped first.
    static let maxQueueSize = 1_000
    /// Coalesces the storage write behind a burst of track() calls.
    static let persistDebounce: TimeInterval = 1
    /// Ceiling on events tracked before storage answers; beyond this the read is wedged.
    static let maxPendingEvents = 100
    /// Matches the ingestion contract so an identity can never bucket but fail to track.
    static let maxUserIdLength = 255
}

enum StorageKey {
    static let anonymousId = "anonymousId"
    static let userId = "userId"
    static let config = "config"
    static let queue = "queue"
    static let assignments = "assignments"
}

/// String rules the JavaScript SDKs apply, so every SDK accepts and rejects the same input.
enum JSString {
    /// Exactly what String.prototype.trim strips (ECMA-262 WhiteSpace and LineTerminator).
    private static let whitespace: Set<UInt16> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
    ]

    static func isWhitespace(_ unit: UInt16) -> Bool {
        whitespace.contains(unit)
    }

    static func isBlank(_ value: String) -> Bool {
        value.utf16.allSatisfy(isWhitespace)
    }

    static func trimmed(_ value: String) -> [UInt16] {
        let units = Array(value.utf16)
        guard let start = units.firstIndex(where: { !isWhitespace($0) }),
            let end = units.lastIndex(where: { !isWhitespace($0) })
        else { return [] }
        return Array(units[start...end])
    }
}
