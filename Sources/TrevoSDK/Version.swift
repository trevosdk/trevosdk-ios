public enum TrevoSDKVersion {
    /// Matches the release tag `ios-v<version>`; the release workflow refuses a mismatch.
    public static let current = "0.1.4"

    static let sdkVersion = "ios-\(current)"
    static let userAgent = "trevosdk-ios/\(current)"
}
