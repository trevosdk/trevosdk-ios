// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrevoSDK",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .visionOS(.v1)],
    products: [
        .library(name: "TrevoSDK", targets: ["TrevoSDK"])
    ],
    targets: [
        .target(name: "TrevoSDK", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "TrevoSDKTests", dependencies: ["TrevoSDK"]),
    ]
)
