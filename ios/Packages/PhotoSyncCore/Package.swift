// swift-tools-version: 6.0
// PhotoSyncCore: the logic the iPhone app needs, kept free of UI and of anything Apple-only so
// that `swift test` runs on a Linux CI runner. No third-party dependencies (project constraint).
import PackageDescription

let package = Package(
    name: "PhotoSyncCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PhotoSyncCore", targets: ["PhotoSyncCore"]),
    ],
    targets: [
        .target(name: "PhotoSyncCore"),
        .testTarget(name: "PhotoSyncCoreTests", dependencies: ["PhotoSyncCore"]),
    ]
)
