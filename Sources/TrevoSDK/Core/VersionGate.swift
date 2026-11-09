/// `minAppVersion` gating, matching the React Native SDK and the server's version order.
enum VersionGate {
    /// Compares dotted versions numerically; pre-release and build suffixes are ignored.
    static func compare(_ a: String, _ b: String) -> Int {
        let left = parts(a)
        let right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    /// Fails closed: a treatment on a build without its code is a broken screen, while excluding
    /// the device only costs sample.
    static func admits(appVersion: String?, platform: String, minimum: MinAppVersion?) -> Bool {
        let ios = minimum?.ios ?? ""
        let android = minimum?.android ?? ""
        if ios.isEmpty && android.isEmpty { return true }

        let required = platform == "android" ? android : ios
        if required.isEmpty { return true }
        guard let appVersion, isParsable(appVersion) else { return false }
        return compare(appVersion, required) >= 0
    }

    private static let dot: UInt16 = 0x2E
    private static let minus: UInt16 = 0x2D
    private static let plus: UInt16 = 0x2B

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isParsable(_ version: String) -> Bool {
        JSString.trimmed(version).first.map(isDigit) ?? false
    }

    // Suffix is split off before the dots, or `1.4.0-beta.2` gains a fourth segment.
    private static func parts(_ version: String) -> [Double] {
        let core = JSString.trimmed(version).prefix { $0 != minus && $0 != plus }
        return core.split(separator: dot, omittingEmptySubsequences: false).map(leadingNumber)
    }

    /// `Number.parseInt` on a segment that has no sign: leading digits after whitespace, else 0.
    private static func leadingNumber(_ segment: ArraySlice<UInt16>) -> Double {
        let digits = segment.drop(while: JSString.isWhitespace).prefix(while: isDigit)
        return digits.reduce(0.0) { $0 * 10 + Double($1 - 0x30) }
    }
}
