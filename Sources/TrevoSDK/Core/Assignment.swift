import Foundation

/// Frozen contract: every Trevo SDK must assign identically. Read docs/sdk/bucketing-spec.md and
/// run the shared vectors before touching this.
enum Assignment {
    /// FNV-1a 32 over UTF-16 code units, not UTF-8 bytes.
    static func fnv1a32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for unit in input.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    static func bucket(_ bucketingId: String, _ experimentKey: String) -> UInt32 {
        fnv1a32("\(bucketingId):\(experimentKey)") % Constants.bucketSpace
    }

    static func assignVariant(_ bucketingId: String, _ config: ExperimentConfig) -> String {
        guard let last = config.variants.last else { return Constants.controlVariant }
        let bucket = Double(bucket(bucketingId, config.experimentKey))
        // Double, as in JavaScript, so an out-of-range split walks the same way instead of overflowing.
        var cumulative = 0.0
        for variant in config.variants {
            cumulative += Double(variant.trafficSplit) * 100
            if bucket < cumulative { return variant.name }
        }
        return last.name
    }

    /// The arm holding all traffic, as a shipped winner or a hold on control does. Everyone gets it.
    static func settledVariant(_ config: ExperimentConfig) -> String? {
        config.variants.first { $0.trafficSplit >= 100 }?.name
    }

    /// The user id when usable, else the anonymous id. Used verbatim: never trimmed or normalized.
    static func bucketingId(userId: String?, anonymousId: String?) -> String? {
        if let userId, !JSString.isBlank(userId) { return userId }
        if let anonymousId, !JSString.isBlank(anonymousId) { return anonymousId }
        return nil
    }
}
