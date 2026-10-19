// swift-tools-version: 6.0
import PackageDescription

// The fog model, ported from backend/app. No UI and no network: it takes an
// elevation grid, station observations and a sounding, and returns a fog grid.
// macOS is a platform only so `swift test` runs on the host without a simulator.
let package = Package(
    name: "FogKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FogKit", targets: ["FogKit"]),
    ],
    targets: [
        .target(name: "FogKit"),
        .testTarget(
            name: "FogKitTests",
            dependencies: ["FogKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
