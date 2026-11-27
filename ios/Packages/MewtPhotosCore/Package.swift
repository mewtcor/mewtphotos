// swift-tools-version: 6.0
// MewtPhotosCore: the logic the iPhone app needs, kept free of UI and of anything Apple-only so
// that `swift test` runs on a Linux CI runner. No third-party dependencies (project constraint).
import PackageDescription

let package = Package(
    name: "MewtPhotosCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MewtPhotosCore", targets: ["MewtPhotosCore"]),
    ],
    targets: [
        .target(name: "MewtPhotosCore"),
        .testTarget(name: "MewtPhotosCoreTests", dependencies: ["MewtPhotosCore"]),
    ]
)
