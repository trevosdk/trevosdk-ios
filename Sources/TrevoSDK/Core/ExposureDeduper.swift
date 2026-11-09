/// One exposure per identity, experiment and variant per window. The window is corpus-frozen; the
/// eviction strategy is not.
struct ExposureDeduper: Sendable {
    private var seen: [String: Int64] = [:]
    private let maxKeys: Int

    init(maxKeys: Int = Constants.exposureDedupMaxKeys) {
        self.maxKeys = maxKeys
    }

    mutating func shouldLog(
        identity: String, experimentKey: String, variant: String, nowMs: Int64
    ) -> Bool {
        if seen.count >= maxKeys {
            seen = seen.filter { nowMs - $0.value < Constants.exposureDedupWindowMs }
            // Still full: start over. At worst one burst of duplicate exposures while it refills.
            if seen.count >= maxKeys { seen.removeAll() }
        }

        let key = "\(identity):\(experimentKey):\(variant)"
        if let last = seen[key], nowMs - last < Constants.exposureDedupWindowMs {
            return false
        }
        seen[key] = nowMs
        return true
    }

    mutating func clear() {
        seen.removeAll()
    }
}
