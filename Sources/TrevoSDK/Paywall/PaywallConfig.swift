import Foundation

/// The page `/v1/config` names under an id. Spec: docs/sdk/remote-paywall.md, section 5.
struct PaywallConfigEntry: Sendable, Equatable {
    let id: String
    let url: String
    let sha256: String
    let format: Int
    let bridge: Int
    /// Keyed by SDK (`ios`, `android`, `flutter`, `reactNative`).
    let minSdkVersion: [String: String]?
}

enum PaywallConfig {
    static let formatVersion = 1
    static let bridgeVersion = 1
    static let sdk = "ios"
    static let sdks: Set<String> = ["ios", "android", "flutter", "reactNative"]
    static let maxPaywalls = 20
    static let maxUrlLength = 2048
    static let maxDocumentBytes = 500 * 1024
    private static let maxSafeInteger: Double = 9_007_199_254_740_991

    /// Never fails: a bad entry is dropped, so a bad paywall can't cost the app its experiments.
    static func parse(_ value: TrevoValue?) -> [PaywallConfigEntry] {
        guard let items = value?.arrayValue else { return [] }
        var entries: [PaywallConfigEntry] = []
        var seen: Set<String> = []
        for item in items {
            guard let parsed = entry(item), !seen.contains(parsed.id) else { continue }
            seen.insert(parsed.id)
            entries.append(parsed)
            if entries.count == maxPaywalls { break }
        }
        return entries
    }

    /// Whether this build of `sdk` at `sdkVersion` can show the entry's page.
    static func canShow(
        _ entry: PaywallConfigEntry, sdk: String = sdk, sdkVersion: String = TrevoSDKVersion.current
    ) -> Bool {
        guard entry.format <= formatVersion, entry.bridge <= bridgeVersion else { return false }
        guard let required = entry.minSdkVersion?[sdk], !required.isEmpty else { return true }
        return VersionGate.compare(sdkVersion, required) >= 0
    }

    static func json(_ entry: PaywallConfigEntry) -> TrevoValue {
        var object: [String: TrevoValue] = [
            "id": .string(entry.id), "url": .string(entry.url), "sha256": .string(entry.sha256),
            "format": .number(Double(entry.format)), "bridge": .number(Double(entry.bridge)),
        ]
        if let gate = entry.minSdkVersion {
            object["minSdkVersion"] = .object(gate.mapValues(TrevoValue.string))
        }
        return .object(object)
    }

    private static func entry(_ value: TrevoValue) -> PaywallConfigEntry? {
        guard let object = value.objectValue,
            let id = object["id"]?.stringValue, isPaywallId(id),
            let url = object["url"]?.stringValue, isPageUrl(url),
            let sha256 = object["sha256"]?.stringValue, isSha256(sha256),
            let format = versionNumber(object["format"]),
            let bridge = versionNumber(object["bridge"])
        else { return nil }
        var gate: [String: String]?
        if let raw = object["minSdkVersion"] {
            guard let parsed = minSdkVersion(raw) else { return nil }
            gate = parsed
        }
        return PaywallConfigEntry(
            id: id, url: url, sha256: sha256, format: format, bridge: bridge, minSdkVersion: gate)
    }

    // A gate this build can't read keeps the page away. Keys of other SDKs are theirs to read.
    private static func minSdkVersion(_ value: TrevoValue) -> [String: String]? {
        guard let object = value.objectValue else { return nil }
        var gate: [String: String] = [:]
        for (key, version) in object where sdks.contains(key) {
            guard let version = version.stringValue else { return nil }
            gate[key] = version
        }
        return gate
    }

    /// `^[a-z0-9][a-z0-9-]{0,39}$`, the folder rule.
    static func isPaywallId(_ id: String) -> Bool {
        let units = Array(id.utf16)
        guard (1...40).contains(units.count) else { return false }
        return units.enumerated().allSatisfy { index, unit in
            let lowerOrDigit = (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit)
            return lowerOrDigit || (index > 0 && unit == 0x2D)
        }
    }

    private static func isPageUrl(_ url: String) -> Bool {
        let units = url.utf16
        guard units.count <= maxUrlLength, units.count > 8, units.starts(with: "https://".utf16) else {
            return false
        }
        return units.allSatisfy { $0 > 0x20 && $0 != 0x7F }
    }

    private static func isSha256(_ value: String) -> Bool {
        value.utf16.count == 64
            && value.utf16.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func versionNumber(_ value: TrevoValue?) -> Int? {
        guard let number = value?.numberValue, number.rounded() == number, number >= 1,
            number <= maxSafeInteger
        else { return nil }
        return Int(number)
    }
}
